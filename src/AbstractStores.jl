"""
    AbstractStores

A small, backend-agnostic interface for storing simple state.

Lots of libraries need to persist a little bit of state — a refresh token, a set
of scheduled jobs, a session, a cursor — and every one of them ends up defining
its own `AbstractFooStore` with an in-memory and a file-based implementation, and
a documented escape hatch for "bring your own persistence".  `AbstractStores`
factors that out: a library declares it needs an `AbstractStore{Job}`, and the
*application* decides whether that lives in a `Dict`, a directory, Redis,
Postgres, or S3.

Where `DBInterface.jl` abstracts over *databases* (connections, prepared
statements, cursors, result sets), `AbstractStores` abstracts over *persistence*
at the level of get/put/delete/list — deliberately less powerful, and therefore
implementable by things that are not databases at all.  The SQL backend here is
in fact built *on* `DBInterface`, one layer down.

# The interface

    get(store, key, default)              # fetch, or default if absent/expired
    put!(store, key, value; ttl=nothing)  # write, optionally with an expiry
    delete!(store, key)                   # remove
    keys(store; prefix="")                # enumerate

plus derived operations `store[key]`, `store[key] = value`, `haskey`, `length`,
`isempty`, `empty!`, `pairs`, and three built on a single atomic primitive:

    modify!(f, store, key)                # atomic read-modify-write
    pop!(store, key[, default])           # atomic consume (single-use)
    get!(store, key, default)             # atomic get-or-create

Three traits tell a caller what a given backend actually guarantees:
[`AbstractStores.supportsttl`](@ref), [`AbstractStores.supportslisting`](@ref),
and [`AbstractStores.isatomic`](@ref) — and [`checkstore`](@ref) asserts the
ones your code depends on, at configuration time.

# Backends

Built in: [`MemoryStore`](@ref), [`FileStore`](@ref), and the
[`PrefixedStore`](@ref) namespacing view.  Loading the relevant package activates
an extension providing more:

| `using ...` | store |
|:---|:---|
| `JSON` | [`JSONCodec`](@ref) for portable on-disk values |
| `Redis` | `RedisStore` |
| `DBInterface` + SQLite/MySQL/Postgres | `SQLStore` |
| `CloudStore` | `ObjectStore` (S3, Azure Blobs, GCS) |
| `Test` | [`AbstractStores.runstoretests`](@ref), the conformance suite |

# Implementing a store

Implement the four required methods, declare your traits, and run the suite:

```julia
using AbstractStores, Test
AbstractStores.runstoretests(() -> MyStore{String}(), ["a", "b", "c"])
```

See `?AbstractStore` for the full contract.
"""
module AbstractStores

using Dates, Serialization, Base64

export AbstractStore, MemoryStore, FileStore, PrefixedStore,
       SQLStore, RedisStore, ObjectStore,
       SerializedCodec, RawCodec, JSONCodec,
       modify!, sweep!, checkstore

include("interface.jl")
include("codecs.jl")
include("memory.jl")
include("file.jl")
include("prefixed.jl")
# Backend types are declared here — package extensions cannot add names to their
# parent's namespace — while their methods live in `ext/`.
include("sql.jl")
include("redis.jl")
include("object.jl")

"""
    AbstractStores.runstoretests(makestore, values; name="", concurrency=true)

Run the `AbstractStores` conformance suite against a store implementation.

This is the contract, executable.  Every backend in this package runs it, and any
package implementing [`AbstractStore`](@ref) should too — if your store passes,
code written against the interface will work with it.

# Arguments
- `makestore`: a zero-argument function returning a **fresh, empty** store.  It is
  called several times; each call must yield a store that does not share state
  with the previous one (or that has been emptied).
- `values`: a vector of at least three distinct, `==`-comparable values of the
  store's `eltype`, used as test payloads.  Defaults to `["one", "two", "three"]`.

# Keywords
- `name`: label for the enclosing `@testset` (defaults to the store's type)
- `concurrency`: run the multi-task race tests.  Only meaningful when
  [`isatomic`](@ref) is `true`; skipped automatically otherwise.
- `trickykeys`: the awkward keys to exercise — separators, spaces, unicode,
  punctuation, case and accent pairs.  Narrow it only for a backend that
  genuinely cannot represent the full set, and say why: a store quietly mangling
  or *merging* keys is the bug this catches.  The `"case"`/`"CASE"` pair also
  gates the byte-exact prefix tests; drop it only for a test harness that cannot
  keep case-distinct keys apart (e.g. Minio persisting to a case-insensitive
  filesystem), never for a real service.

The suite adapts to the store's traits: TTL tests run only when
[`supportsttl`](@ref) is `true` — and when it is `false`, it separately asserts
that the store *rejects* a `ttl` rather than silently ignoring it.  Listing tests
run only when [`supportslisting`](@ref) is `true`.

!!! note "Requires Test"
    Lives in a package extension; `using Test` to enable it.

# Examples
```julia
using AbstractStores, Test

AbstractStores.runstoretests(() -> MemoryStore{String}(), ["a", "b", "c"])

AbstractStores.runstoretests(["x", "y", "z"]; name="RedisStore") do
    store = RedisStore{String}(conn; prefix="test:")
    empty!(store)
    store
end
```
"""
function runstoretests end

end # module
