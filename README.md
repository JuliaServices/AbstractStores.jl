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

## How this relates to DBInterface.jl

`DBInterface.jl` abstracts over *databases*: connections, prepared statements,
cursors, result sets. `AbstractStores` abstracts over *persistence* at the level
of get/put/delete/list — deliberately less powerful, and therefore implementable
by things that are not databases at all, like a directory or an S3 bucket.

They compose rather than compete: the `SQLStore` here is implemented once against
`DBInterface`, one layer down, which is why SQLite, MySQL, and Postgres all work
from a single ~180-line extension.

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
| `get!(store, key, default)` | atomic get-or-create — first writer wins |

Keys are always `String`. Values are always `eltype(store)`. `AbstractStore` is
deliberately **not** an `AbstractDict`: a store may live on another machine, where
`length` is expensive, iteration is not free, and operations can fail.

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

## Backends

Built in — `MemoryStore`, `FileStore`, and the `PrefixedStore` namespacing view.
Loading the relevant package activates an extension providing the rest:

| `using ...` | provides | ttl | listing | atomic |
|:---|:---|:---:|:---:|:---:|
| *(built in)* | `MemoryStore` | ✔ | ✔ | ✔ |
| *(built in)* | `FileStore` — one file per key | ✔¹ | ✔ | ✖² |
| `DBInterface` + SQLite/MySQL/Postgres | `SQLStore` | ✔ | ✔ | ✔³ |
| `Redis` | `RedisStore` | ✔ | ✔ | ✔⁴ |
| `CloudStore` | `ObjectStore` — S3, Azure Blobs, GCS | ✔¹ | ✔ | ✖ |
| `JSON` | `JSONCodec` | | | |
| `Test` | `AbstractStores.runstoretests`, the conformance suite | | | |

1. Expiry rides along in the encoded envelope and is applied lazily on read;
   `sweep!` reclaims. Not available with `RawCodec`, which has nowhere to put it.
2. Individual `put!`s are atomic (temp file + rename); a read-modify-write is
   serialized only against other tasks in the same process.
3. Optimistic concurrency: each row carries a random token and every write is
   conditional on the token the reader saw, with the write and its verification
   sharing a short transaction. No `SELECT ... FOR UPDATE`, no dialect-specific
   row-locking semantics.
4. A compare-and-swap `EVAL` script, comparing a token rather than the value, so
   an A→B→A sequence is correctly detected as a conflict.

For 3 and 4: `f` may run more than once, which is inherent to compare-and-swap.
Keep it pure.

Every backend is held to the same conformance suite against a real service —
SQLite in-process, Postgres/MySQL/Redis in throwaway containers via
[Harbor.jl](https://github.com/JuliaServices/Harbor.jl), and object storage
against a local Minio. See [`test/services.jl`](test/services.jl); anything whose
service is unavailable skips loudly rather than silently.

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

## Namespacing

`PrefixedStore` lets several logically separate stores share one backend, which is
how a library with three kinds of state avoids demanding three Redis connections:

```julia
backend = RedisStore{Any}(client)
tokens  = PrefixedStore{TokenResponse}(backend, "oauth/refresh/")
codes   = PrefixedStore{CodeRecord}(backend, "oauth/code/")

empty!(codes)          # scoped — leaves `tokens` alone
```

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
passes it.

## Migrating an existing store hierarchy

`examples/` contains worked, executable migrations, exercised by the test suite:

- [`examples/oauth.jl`](examples/oauth.jl) — OAuth.jl's three abstract types
  (`RefreshTokenStore`, `AccessTokenStore`, `AuthorizationCodeStore`) as one
  interface. `consume_authorization_code!` becomes `pop!`; token expiry becomes
  `ttl`; the hand-written `FileBasedRefreshTokenStore` becomes `FileStore`; and
  `check_single_use` turns "this deployment cannot actually guarantee single-use
  codes" from a silent weakness into a startup error.
- [`examples/tempus.jl`](examples/tempus.jl) — Tempus.jl's `Store` as two stores,
  jobs and bounded execution history. `InMemoryStore`/`FileStore`/`SQLiteStore`
  collapse into whatever the caller passed, execution history becomes persistent
  (Tempus's file backend drops it today), and multi-process scheduling via
  `claim!` becomes expressible for the first time.

## Running the tests

```bash
julia --project=test -t4 test/runtests.jl
```

Docker is required for the Postgres, MySQL, and Redis backends; without it those
testsets skip. Image refs are overridable via `ABSTRACTSTORES_POSTGRES_IMAGE`,
`ABSTRACTSTORES_MYSQL_IMAGE`, and `ABSTRACTSTORES_REDIS_IMAGE`.

All five backends run the same conformance suite: SQLite, Postgres, and MySQL
each execute it three times (over `String`, `Int`, and a struct via `JSONCodec`),
so the three SQL dialects are held to an identical contract.

Test dependencies live in `[extras]`/`[targets]` in `Project.toml` — there is no
separate `test/Project.toml`. Only registry-resolvable packages are declared
there, so `Pkg.test` works for anyone. The Postgres, Redis, and object-storage
backends need packages not yet in General (JuliaServices/Postgres.jl,
JuliaServices/Redis.jl, and CloudBase's HTTP 2.x); `test/backends.jl` loads those
opportunistically and skips loudly without them.

To exercise every backend, run the suite from an environment that has them
`develop`ed:

```julia
using Pkg
Pkg.activate(temp=true)
Pkg.develop([PackageSpec(path=p) for p in
    ["/path/to/AbstractStores", "/path/to/Postgres", "/path/to/Redis",
     "/path/to/CloudStore", "/path/to/CloudBase", "/path/to/HTTP", "/path/to/Reseau"]])
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
- **Two different `Redis.jl`s.** The `Redis` extension targets the JuliaServices
  package (UUID `ea172dcb-…`), not the `Redis.jl` registered in General under
  `0cf705f9-…`.
- Backend *types* (`SQLStore`, `RedisStore`, `ObjectStore`) are declared in the
  core package while their *methods* live in extensions, because a package
  extension cannot add names to its parent's namespace. Constructing one without
  its extension loaded tells you which package to load.

## License

MIT.
