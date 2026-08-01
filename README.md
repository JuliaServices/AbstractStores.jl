# AbstractStores.jl

[![](https://img.shields.io/badge/docs-stable-blue.svg)](https://JuliaServices.github.io/AbstractStores.jl/stable)
[![](https://img.shields.io/badge/docs-dev-blue.svg)](https://JuliaServices.github.io/AbstractStores.jl/dev)
[![Build Status](https://github.com/JuliaServices/AbstractStores.jl/workflows/CI/badge.svg)](https://github.com/JuliaServices/AbstractStores.jl/actions?query=workflow%3ACI+branch%3Amain)
[![codecov.io](http://codecov.io/github/JuliaServices/AbstractStores.jl/coverage.svg?branch=main)](http://codecov.io/github/JuliaServices/AbstractStores.jl?branch=main)

A small, backend-agnostic interface for storing simple state.

Lots of Julia libraries need to persist a little bit of state — a refresh token, a
set of scheduled jobs, a session, a cursor — and every one of them ends up
defining its own `AbstractFooStore`, an in-memory implementation, a file-based
implementation with hand-rolled locking and atomic renames, and a callback escape
hatch for "bring your own persistence". That is the same 300 lines written over
and over, and it still leaves the *application* unable to say "actually, put this
in Redis".

`AbstractStores` factors that out. A library declares that it needs an
`AbstractStore{Job}`; the application decides whether that lives in a `Dict`, a
directory, SQLite, Postgres, Redis, or S3.

```julia
using AbstractStores

store = MemoryStore{String}()

store["session/abc"] = "user-42"           # write
get(store, "session/abc", nothing)         # read, with a default
put!(store, "code/xyz", "grant"; ttl=Second(30))   # write with an expiry
pop!(store, "code/xyz", nothing)           # atomic single-use consume
collect(keys(store; prefix="session/"))    # prefix listing
delete!(store, "session/abc")
```

Swapping the backend is the only line that changes:

```julia
store = FileStore{String}("~/.myapp/state"; codec=JSONCodec())   # a directory
store = SQLStore{String}(SQLite.DB("state.db"))                  # a SQL table
store = RedisStore{String}(Redis.connect("localhost"))           # Redis
store = ObjectStore{String}(AWS.Bucket("my-state"))              # S3/Azure/GCS
```

## What this is — and what it is not

**This package is for small, named state.** A store maps non-empty `String`
keys to whole values of one type. Every operation moves the whole value. That
scope is deliberate, and it is the reason the same four methods are
implementable by a `Dict`, a directory, a SQL table, Redis, and an S3 bucket
alike.

**In scope** — and this is the whole point:

- `get` / `put!` / `delete!` / `keys`, with prefix namespacing
- **expiry as part of the contract**: `ttl` on any write, honored by the
  backend or *rejected loudly* — never silently ignored
- **atomic primitives**: `pop!` (single-use consume — authorization codes,
  one-time tokens, work claims), `get!` (get-or-create — leases, first-writer
  wins), and `modify!` (read-modify-write — counters, bounded lists), all
  guarded by an honest `isatomic` trait
- **traits over promises**: `supportsttl` / `supportslisting` / `isatomic`
  say what a backend actually guarantees, and `checkstore` turns "this
  deployment is quietly broken" into a startup error
- **an executable contract**: `AbstractStores.runstoretests` is the
  conformance suite every backend here passes, and yours should too

**Deliberately out of scope** — we will say no:

- **Batch operations.** No multi-get, no bulk write. If per-key round-trips
  dominate your workload, you have outgrown this interface.
- **Queues.** No ordering, no blocking take, no delivery guarantees, no
  visibility timeouts. `pop!` consumes a *named* key; it is not "give me the
  next item". Use a real queue.
- **Large values and datasets.** No ranged reads, no chunking, no streaming.
  A store holds tokens, jobs, and sessions — not arrays, parquet files, or
  gigabyte blobs.
- **Querying.** Keys and prefixes are the only index. If you want secondary
  indexes or predicates, you want a database —
  [DBInterface.jl](https://github.com/JuliaDatabases/DBInterface.jl) is one
  layer down and does that well.
- **Project configuration.** Preferences.jl already owns package/project
  config; this is for *runtime* state.

**Open to, eventually:** watch/subscribe (change notification). It composes
with the current interface rather than distorting it, so if you have a concrete
use case, open an issue.

## How this relates to DBInterface.jl

`DBInterface.jl` abstracts over *databases*: connections, prepared statements,
cursors, result sets. `AbstractStores` abstracts over *persistence* at the level
of get/put/delete/list — deliberately less powerful, and therefore implementable
by things that are not databases at all, like a directory or an S3 bucket.

They compose rather than compete: the `SQLStore` here is implemented once against
`DBInterface`, one layer down, which is why SQLite, MySQL, and Postgres all work
from a single ~200-line extension.

## The interface

Four methods are required:

| Method | Purpose |
|:---|:---|
| `get(store, key, default)` | fetch a value, or `default` if absent/expired |
| `put!(store, key, value; ttl=nothing)` | write, optionally with a time-to-live |
| `delete!(store, key)` | remove a key |
| `keys(store; prefix="")` | enumerate keys |

Everything else has a working fallback: `store[key]`, `store[key] = value`,
`haskey`, `length`, `isempty`, `empty!`, `pairs`, `sweep!`, and three operations
built on one atomic primitive:

| Method | Purpose |
|:---|:---|
| `modify!(f, store, key)` | atomic read-modify-write; returning `nothing` deletes |
| `pop!(store, key[, default])` | atomic consume — single-use tokens, work claims |
| `get!(store, key, default)` | atomic get-or-create — first writer wins, leases |

Keys are non-empty `String`s. Whatever keys a backend accepts it preserves
byte-exactly — case, accents, separators, and trailing characters never fold or
collide, on any backend — though per-backend limits on what is *accepted* exist
and are documented with each backend (MySQL: 512 bytes; `FileStore`: 228
encoded bytes; `ObjectStore`: no space or `%` yet). Values are always
`eltype(store)`. `AbstractStore` is deliberately **not** an `AbstractDict`: a
store may live on another machine, where `length` is expensive, iteration is
not free, and operations can fail.

One sharp edge worth knowing before you use `modify!`: returning the *identical*
object you were passed means "no change" — so never mutate the value in place;
`copy` it first. See `?modify!`.

### Traits: what a backend actually guarantees

The backends here differ in ways callers genuinely need to know about, so three
traits are part of the contract:

```julia
AbstractStores.supportsttl(store)      # does `ttl` work?
AbstractStores.supportslisting(store)  # can `keys` enumerate?
AbstractStores.isatomic(store)         # is `modify!`/`pop!` atomic against *all* writers?
```

A store that ignores a requested `ttl` must report `supportsttl == false`, and
then `put!(...; ttl=...)` **throws** rather than silently persisting a single-use
authorization code forever. Silently dropping an expiry is a security bug, not a
performance detail.

`isatomic` is the one to check before building on `pop!`. It is `true` for
`MemoryStore` (within a process) and for `SQLStore`/`RedisStore` (across
processes), and `false` for `FileStore` and `ObjectStore`, which can only
serialize writers inside a single process.

Libraries should assert what they depend on **once, at configuration time**,
with `checkstore`:

```julia
# an OAuth server: authorization codes must be single-use and short-lived
codes = checkstore(store; atomic=true, ttl=true)
```

## Backends

Built in — `MemoryStore`, `FileStore`, and the `PrefixedStore` namespacing view.
Loading the relevant package activates an extension providing the rest:

| `using ...` | provides | ttl | listing | atomic |
|:---|:---|:---:|:---:|:---:|
| *(built in)* | `MemoryStore` | ✔ | ✔ | ✔ |
| *(built in)* | `FileStore` — one file per key | ✔¹ | ✔ | ✖² |
| `DBInterface` + SQLite/MySQL/Postgres | `SQLStore` | ✔ | ✔ | ✔³ |
| `Redis`⁵ | `RedisStore` | ✔ | ✔ | ✔⁴ |
| `CloudStore` | `ObjectStore` — S3, Azure Blobs, GCS | ✔¹ | ✔ | ✖ |
| `JSON` | `JSONCodec` | | | |
| `Test` | `AbstractStores.runstoretests`, the conformance suite | | | |

1. Expiry rides along in the encoded envelope and is applied lazily on read;
   `sweep!` reclaims. Not available with `RawCodec`, which has nowhere to put it.
2. Individual `put!`s are atomic (rename over the destination); a
   read-modify-write is serialized only against other tasks in the same process.
   Filenames are canonically encoded, so keys differing only in case or unicode
   normalization stay distinct even on the case-insensitive filesystems that are
   the default on macOS and Windows.
3. Optimistic concurrency: each row carries a random token and every write is
   conditional on the token the reader saw, with the write and its verification
   sharing a short transaction. No `SELECT ... FOR UPDATE`, no dialect-specific
   row-locking semantics. The MySQL key column is `VARBINARY` — every utf8mb4
   collation folds *something*: case and accents by default, trailing spaces
   even under `utf8mb4_bin` — and prefix matching carries a byte-exact guard on
   all three dialects.
4. A compare-and-swap Lua script (loaded once, invoked by SHA), comparing a
   token rather than the value, so an A→B→A sequence is correctly detected as a
   conflict.
5. The Redis backend targets [JuliaServices/Redis.jl](https://github.com/JuliaServices/Redis.jl),
   which is not registered in General yet — and a registered package cannot
   declare an unregistered weakdep, so the extension is not in `Project.toml`
   until Redis.jl registers. It is implemented and held to the full conformance
   suite (the tests load the extension file directly); see `?RedisStore` for
   how to use it today.

For 3 and 4: `f` may run more than once, which is inherent to compare-and-swap.
Keep it pure.

Every backend is held to the same conformance suite against a real service —
SQLite in-process, Postgres/MySQL/Redis in throwaway containers via
[Harbor.jl](https://github.com/JuliaServices/Harbor.jl) (see
[`test/services.jl`](test/services.jl)), and object storage against a local
Minio via CloudBase's own CloudTest harness, no Docker needed (see
[`test/backends.jl`](test/backends.jl)). Anything whose service is unavailable
skips loudly rather than silently.

## Codecs

Where the bytes live and how a value becomes bytes are separate decisions:

- `SerializedCodec()` — the default. Handles any Julia value, no dependencies.
  Makes no compatibility promises across Julia versions or struct changes: fine
  for a cache, wrong for anything you want to read next year.
- `JSONCodec()` — portable, human-readable, `cat`-able. Requires `using JSON`.
  The right default for state that outlives a version of your program.
- `RawCodec()` — identity, for `AbstractStore{String}` or
  `AbstractStore{Vector{UInt8}}`. The object in your bucket is exactly the bytes
  you put there.

One rule to remember: **decoding happens at the store's `eltype`**. With
`JSONCodec`, use concretely-typed stores (`SQLStore{Job}`, `FileStore{Config}`)
— a `FileStore{Any}` with a JSON codec hands you back `Dict`s, not your structs.
`SerializedCodec` preserves types regardless.

## Namespacing

`PrefixedStore` lets several logically separate stores share one backend, which is
how a library with three kinds of state avoids demanding three Redis connections:

```julia
backend = RedisStore{Any}(client)
tokens  = PrefixedStore{TokenResponse}(backend, "oauth/refresh/")
codes   = PrefixedStore{CodeRecord}(backend, "oauth/code/")

empty!(codes)          # scoped — leaves `tokens` alone
```

Typed views like the above require a type-preserving parent (`MemoryStore`, or
any store with `SerializedCodec`); with `JSONCodec`, give each kind of state its
own concretely-typed store instead. See `?PrefixedStore`.

## Implementing a store

Implement the four required methods, declare your traits, then run the
conformance suite — it *is* the contract, executable:

```julia
using AbstractStores, Test

AbstractStores.runstoretests(() -> MyStore{String}(), ["a", "b", "c"])
```

It adapts to your traits (TTL tests only when you support TTL; concurrency tests
only when you claim atomicity) and separately checks that a store *without* TTL
support rejects a `ttl` rather than ignoring it. Every backend in this package
passes it — including the awkward keys: case pairs, accent pairs, trailing dots
and spaces, separators, and path-traversal shapes, because a store quietly
mangling or *merging* keys is exactly the bug the suite exists to catch. (The
`ObjectStore` harness excludes only what its own tooling cannot represent: keys
CloudBase cannot transmit yet, and the case pair when the local Minio sits on a
case-insensitive disk.)

## Who is using it

Adoption in progress — these PRs replace hand-rolled store hierarchies with this
interface and are worked, reviewable migrations:

- [OAuth.jl #41](https://github.com/JuliaServices/OAuth.jl/pull/41) — three
  abstract store types (refresh tokens, access tokens, authorization codes)
  become one interface. `consume_authorization_code!` is `pop!`, token expiry is
  `ttl`, and `checkstore(...; atomic=true, ttl=true)` turns "this deployment
  cannot actually guarantee single-use codes" from a silent weakness into a
  startup error.
- [Tempus.jl #3](https://github.com/JuliaServices/Tempus.jl/pull/3) — scheduler
  jobs and bounded execution history as two stores. The scheduler states what it
  needs and stays out of the persistence question; multi-process job leases
  become expressible for the first time.

Natural next candidates:

- [JWTs.jl](https://github.com/JuliaWeb/JWTs.jl) — JWKS keyset caching and
  refresh is a TTL'd store one line deep.
- [ExpiringCaches.jl](https://github.com/JuliaServices/ExpiringCaches.jl) — a
  TTL'd `Dict` behind a memoizing macro; an `AbstractStore` backend would give
  it persistence and multi-process sharing for free — or use `MemoryStore` +
  `get!` directly for expiring-cache needs.

## Running the tests

```bash
julia --project -e 'using Pkg; Pkg.test(; julia_args=["-t4"])'
```

Docker is required for the Postgres, MySQL, and Redis backends; without it those
testsets skip. Image refs are overridable via `ABSTRACTSTORES_POSTGRES_IMAGE`,
`ABSTRACTSTORES_MYSQL_IMAGE`, and `ABSTRACTSTORES_REDIS_IMAGE`.

Every backend runs the same conformance suite; SQLite, Postgres, and MySQL
each execute it three times (over `String`, `Int`, and a struct via `JSONCodec`),
so the three SQL dialects are held to an identical contract.

Test dependencies live in `[extras]`/`[targets]` in `Project.toml` — there is no
separate `test/Project.toml`. Only registry-resolvable packages are declared
there, so `Pkg.test` works for anyone. The Postgres, Redis, and object-storage
backends need packages not yet in General (JuliaServices/Postgres.jl,
JuliaServices/Redis.jl, and CloudBase's HTTP 2.x); `test/backends.jl` loads those
opportunistically and skips loudly without them.

To exercise every backend, run the suite from an environment that has them
`develop`ed (start Julia with `-t4` so the concurrency testsets get real
parallelism):

```julia
using Pkg
Pkg.activate(temp=true)
Pkg.develop([PackageSpec(path=p) for p in
    ["/path/to/AbstractStores", "/path/to/Postgres", "/path/to/Redis",
     "/path/to/CloudStore", "/path/to/CloudBase", "/path/to/HTTP", "/path/to/Reseau",
     "/path/to/StructUtils"]])   # Postgres.jl currently needs an unreleased StructUtils
Pkg.add(["Test", "JSON", "DBInterface", "SQLite", "MySQL", "Harbor", "Sockets", "Dates"])
include("/path/to/AbstractStores/test/runtests.jl")
```

## Notes

- **Two different `AbstractStore`s.** `CloudBase.jl` also defines an abstract type
  named `AbstractStore` — the supertype of its `Bucket`/`Container` handles. It is
  unrelated to this one; qualify the name if you load both.
- **A few object keys are not storable yet.** CloudBase puts the key into the
  request path verbatim and does not canonicalize an existing `%` for signing, so
  a key containing a space (400) or a `%` (403) cannot be stored by any spelling
  ([CloudBase.jl#44](https://github.com/JuliaServices/CloudBase.jl/issues/44)).
  `ObjectStore` rejects those up front instead of surfacing an opaque HTTP error.
  Everything else — nested `a/b/c`, unicode, `+`, `&`, `#` — works, and the other
  backends handle arbitrary keys.
- **Two different `Redis.jl`s.** The Redis extension targets the JuliaServices
  package (UUID `ea172dcb-…`), not any `Redis.jl` in General — and it stays
  undeclared in `Project.toml` until that package is registered (see the
  backends table).
- Backend *types* (`SQLStore`, `RedisStore`, `ObjectStore`) are declared in the
  core package while their *methods* live in extensions, because a package
  extension cannot add names to its parent's namespace. Constructing one without
  its extension loaded tells you which package to load.

## License

MIT.
