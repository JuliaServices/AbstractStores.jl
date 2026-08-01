# The AbstractStore interface: generic function definitions, semantics, and fallbacks.

"""
    AbstractStore{T}

Abstract supertype for simple key-value state stores holding values of type `T`.

Keys are always `String`s; values are always of type `T` (`eltype(store)`).
Whatever keys a backend accepts it must preserve *exactly* — case, accents,
separators, and trailing characters never fold or collide.  Per-backend limits
on what is accepted do exist and are documented with each backend: the empty
key is not portable (`FileStore` rejects it — it has no filename), `FileStore`
bounds the encoded key length, MySQL bounds keys at 512 bytes, and `ObjectStore`
currently rejects a space or `%`.  The
interface deliberately mirrors `AbstractDict` where the semantics line up, but
`AbstractStore` is *not* an `AbstractDict`: a store may live in another process,
on another machine, or in a cloud bucket, where operations can fail, `length` can
be expensive or unavailable, and iteration is not free.  Inheriting `AbstractDict`
would promise semantics most backends cannot honor.

# Required interface

A concrete store `S <: AbstractStore{T}` must implement:

| Method | Purpose |
|:---|:---|
| `Base.get(store, key, default)` | fetch a value, or `default` if absent/expired |
| `Base.put!(store, key, value; ttl=nothing)` | write a value, optionally with a time-to-live |
| `Base.delete!(store, key)` | remove a key (no error if absent) |
| `Base.keys(store; prefix="")` | iterate keys, optionally restricted to those starting with `prefix` |

# Optional interface

Everything below has a working fallback, but backends should override any
operation they can perform more efficiently or more atomically:

| Method | Default |
|:---|:---|
| [`modify!`](@ref) | `lock` + `get` + `put!` (see [`isatomic`](@ref)) |
| `Base.pop!(store, key[, default])` | via `modify!` |
| `Base.get!(store, key, default)` | via `modify!` |
| `Base.haskey(store, key)` | via `get` (fetches the whole value) |
| `Base.length` / `Base.isempty` / `Base.empty!` | via `keys` |
| `Base.lock(f, store)` | `f()`, i.e. no locking |
| [`sweep!`](@ref) | no-op returning `0` |
| [`supportsttl`](@ref) / [`supportslisting`](@ref) / [`isatomic`](@ref) | `false` / `true` / `false` |

# Examples

```julia
store = MemoryStore{String}()

store["session/abc"] = "user-42"          # write
get(store, "session/abc", nothing)        # "user-42"
haskey(store, "session/abc")              # true
put!(store, "code/xyz", "grant"; ttl=Second(30))   # write with expiry
pop!(store, "code/xyz", nothing)          # atomic single-use consume
collect(keys(store; prefix="session/"))   # ["session/abc"]
delete!(store, "session/abc")
```

See also [`MemoryStore`](@ref), [`FileStore`](@ref), [`PrefixedStore`](@ref),
and [`AbstractStores.runstoretests`](@ref) for the conformance test suite.
"""
abstract type AbstractStore{T} end

Base.eltype(::Type{<:AbstractStore{T}}) where {T} = T
Base.eltype(store::AbstractStore) = eltype(typeof(store))
Base.keytype(::AbstractStore) = String
Base.valtype(store::AbstractStore) = eltype(store)

# Internal sentinel used to distinguish "absent" from a legitimately stored value.
struct NotFound end
const NOTFOUND = NotFound()

notimplemented(store, f) = throw(ArgumentError(
    "$(typeof(store)) does not implement the required `AbstractStores` method `$f`. " *
    "See `?AbstractStore` for the required interface."))

"""
    AbstractStores.extensionloaded(::Type{<:AbstractStore}) -> Bool

Whether the package extension supplying a backend's methods has been loaded.

[`SQLStore`](@ref), [`RedisStore`](@ref), and [`ObjectStore`](@ref) are declared
here so that `AbstractStores.SQLStore` always resolves — package extensions
cannot add names to their parent's namespace — but their methods live in
extensions.  Constructors consult this to fail with "`using DBInterface`" rather
than a bare `MethodError`.
"""
extensionloaded(::Type{<:AbstractStore}) = false

"""
    AbstractStores.MAX_CAS_ATTEMPTS

How many times a compare-and-swap `modify!` loop retries before throwing a
[`ConcurrencyError`](@ref).  Used by [`SQLStore`](@ref) and [`RedisStore`](@ref).
"""
const MAX_CAS_ATTEMPTS = 100

"""
    AbstractStores.ConcurrencyError(key, attempts)

Thrown when a compare-and-swap `modify!` exceeds [`MAX_CAS_ATTEMPTS`](@ref),
which indicates sustained contention on one key rather than a transient race.
"""
struct ConcurrencyError <: Exception
    key::String
    attempts::Int
end

Base.showerror(io::IO, e::ConcurrencyError) = print(io,
    "ConcurrencyError: gave up modifying key $(repr(e.key)) after $(e.attempts) " *
    "compare-and-swap attempts; another writer keeps winning the race")

#-------------------------------------------------------------------------------
# Traits
#-------------------------------------------------------------------------------

"""
    AbstractStores.supportsttl(store) -> Bool

Whether `store` honors the `ttl` keyword of [`put!`](@ref) and friends.

Defaults to `false`.  Stores that ignore a requested expiry **must** leave this
`false` — passing a `ttl` to a store that does not support it throws, rather than
silently persisting state forever.  That default is deliberate: silently dropping
an expiry on a single-use authorization code or session token is a security bug,
not a performance detail.
"""
supportsttl(::AbstractStore) = false

"""
    AbstractStores.supportslisting(store) -> Bool

Whether `keys(store)` can enumerate the store's keys.  Defaults to `true`.

A store may return `false` if the underlying backend has no listing operation
(e.g. a pure write-through cache), in which case `keys`, `length`, `isempty`, and
`empty!` are expected to throw.
"""
supportslisting(::AbstractStore) = true

"""
    AbstractStores.isatomic(store) -> Bool

Whether [`modify!`](@ref), `pop!`, and `get!` are atomic with respect to *all*
concurrent users of the underlying storage.

Defaults to `false`.  Notable distinctions:

- [`MemoryStore`](@ref) is `true`: the store *is* the storage, guarded by a lock.
- [`FileStore`](@ref) is `false`: writes to a single key are atomic (temp file +
  rename), but a read-modify-write is only serialized against other tasks in the
  same process, not against other processes sharing the directory.
- A Redis- or SQL-backed store implementing `modify!` with a server-side
  compare-and-swap should report `true`.

Callers that need multi-process correctness (leader election, single-use tokens,
counters) should check this trait rather than assuming.
"""
isatomic(::AbstractStore) = false

"""
    checkstore(store; ttl=false, atomic=false, listing=false) -> store

Assert that `store` provides the guarantees your code depends on, throwing a
descriptive `ArgumentError` naming the missing trait otherwise.  Returns `store`,
so it composes at construction sites.

Call this **once, at configuration time** — when your library is handed a store
— rather than hoping the right trait holds at first use.  It turns "this
deployment is quietly broken" (single-use tokens that are not single-use, TTLs
that never expire anything) into an immediate, explainable startup error.

# Examples
```julia
# an OAuth server: authorization codes must be single-use and short-lived
codes = checkstore(store; atomic=true, ttl=true)

# a scheduler lease store
leases = checkstore(store; atomic=true, ttl=true)
```
"""
function checkstore(store::AbstractStore; ttl::Bool=false, atomic::Bool=false,
                    listing::Bool=false)
    ttl && !supportsttl(store) && throw(ArgumentError(
        "$(typeof(store)) does not support expiry (`AbstractStores.supportsttl` is " *
        "false), but this use requires `ttl` to work. Use a TTL-capable store " *
        "(MemoryStore, FileStore with an envelope codec, SQLStore, RedisStore)."))
    atomic && !isatomic(store) && throw(ArgumentError(
        "$(typeof(store)) is not atomic (`AbstractStores.isatomic` is false): " *
        "`modify!`/`pop!`/`get!` are subject to races, so single-use tokens, " *
        "leases, and counters are unsafe on it. Use a store with a real " *
        "compare-and-swap (MemoryStore within a process; SQLStore or RedisStore " *
        "across processes)."))
    listing && !supportslisting(store) && throw(ArgumentError(
        "$(typeof(store)) cannot enumerate its keys (`AbstractStores.supportslisting` " *
        "is false), but this use requires `keys`. Use a listing-capable store " *
        "(every backend in AbstractStores lists), or track your keys explicitly."))
    return store
end

#-------------------------------------------------------------------------------
# TTL handling
#-------------------------------------------------------------------------------

"""
    AbstractStores.expiryof(ttl) -> Union{Nothing,DateTime}

Normalize a `ttl` — `nothing`, a `Dates.Period`, or a `Real` number of seconds —
into an absolute UTC expiry instant.  Backends that store an absolute deadline
(files, SQL columns, envelopes) should use this; backends with native relative
expiry (Redis `EX`) can use [`ttlseconds`](@ref) instead.
"""
function expiryof(ttl, now::DateTime=Dates.now(UTC))
    ttl === nothing && return nothing
    ms = ttl isa Dates.Period ? Dates.Millisecond(ttl) : Dates.Millisecond(round(Int, 1000 * Float64(ttl)))
    ms > Dates.Millisecond(0) || throw(ArgumentError("ttl must be positive, got $ttl"))
    return now + ms
end

"""
    AbstractStores.ttlseconds(ttl) -> Union{Nothing,Float64}

Normalize a `ttl` into a number of seconds, for backends with native relative
expiry.  See also [`expiryof`](@ref).
"""
function ttlseconds(ttl)
    ttl === nothing && return nothing
    secs = ttl isa Dates.Period ? Dates.toms(Dates.Millisecond(ttl)) / 1000 : Float64(ttl)
    secs > 0 || throw(ArgumentError("ttl must be positive, got $ttl"))
    return secs
end

"""
    AbstractStores.checkttl(store, ttl)

Throw if `ttl` was requested but `store` does not [`supportsttl`](@ref).  Called
by backends at the top of `put!`; see [`supportsttl`](@ref) for why this is an
error rather than a warning.
"""
function checkttl(store::AbstractStore, ttl)
    ttl === nothing && return nothing
    supportsttl(store) || throw(ArgumentError(
        "$(typeof(store)) does not support the `ttl` keyword; it would silently " *
        "store `$(repr(ttl))` forever. Use a store with `AbstractStores.supportsttl(store) == true`, " *
        "or expire entries yourself."))
    return ttl
end

isexpired(::Nothing, ::DateTime) = false
isexpired(expires::DateTime, now::DateTime) = expires <= now

#-------------------------------------------------------------------------------
# Required operations
#-------------------------------------------------------------------------------

"""
    get(store::AbstractStore{T}, key::AbstractString, default) -> Union{T,typeof(default)}
    get(f::Function, store::AbstractStore, key::AbstractString)

Return the value stored under `key`, or `default` (or `f()`) if the key is absent
or expired.  **Required** — every store must implement the three-argument form.

Expired entries must be reported as absent even if the backend has not physically
reclaimed them yet; see [`sweep!`](@ref).
"""
Base.get(store::AbstractStore, key::AbstractString, default) = notimplemented(store, :get)

function Base.get(f, store::AbstractStore, key::AbstractString)
    value = get(store, key, NOTFOUND)
    return value === NOTFOUND ? f() : value
end

"""
    put!(store::AbstractStore{T}, key::AbstractString, value::T; ttl=nothing) -> store

Store `value` under `key`, replacing any existing entry.  **Required.**

`ttl` is a time-to-live: `nothing` (no expiry), a `Dates.Period`, or a `Real`
number of seconds.  Passing a `ttl` to a store that does not
[`supportsttl`](@ref) throws an `ArgumentError`.

`store[key] = value` is shorthand for the no-TTL case.

# Examples
```julia
put!(store, "refresh_token", tok)
put!(store, "auth_code/\$code", record; ttl=Dates.Second(60))
```
"""
Base.put!(store::AbstractStore, key::AbstractString, value; ttl=nothing) =
    notimplemented(store, :put!)

"""
    delete!(store::AbstractStore, key::AbstractString) -> store

Remove `key` from `store`.  **Required.**  Deleting an absent key is not an
error.  Use [`pop!`](@ref) to retrieve the value as it is removed.
"""
Base.delete!(store::AbstractStore, key::AbstractString) = notimplemented(store, :delete!)

"""
    keys(store::AbstractStore; prefix="") -> iterator of String

Iterate the keys currently held by `store`, optionally restricted to keys
starting with `prefix`.  **Required** unless [`supportslisting`](@ref) is `false`.

Order is unspecified.  Expired-but-not-yet-reclaimed keys must not be yielded.
The result is a snapshot: concurrent writers may add or remove keys while you
iterate, and backends that page (S3, Redis `SCAN`) may not present a consistent
point-in-time view.

`prefix` is the primary namespacing mechanism for stores — see
[`PrefixedStore`](@ref).
"""
Base.keys(store::AbstractStore; prefix::AbstractString="") = notimplemented(store, :keys)

#-------------------------------------------------------------------------------
# Atomic read-modify-write: the one primitive everything else composes from
#-------------------------------------------------------------------------------

"""
    modify!(f, store::AbstractStore{T}, key::AbstractString; ttl=nothing) -> Union{T,Nothing}

Atomically read `key`, apply `f` to the current value, and write back the result.
Returns the new value.

`f` receives the current value, or `nothing` if the key is absent or expired.  Its
return value is interpreted as:

- a value of type `T` — store it under `key` (with `ttl`, if given)
- `nothing` — delete `key`
- **the identical object it was passed** (`new === old`) — leave the entry
  untouched: no write, and no change to any expiry already set on it.  This is
  what lets `get!` be a true get-or-create that does not disturb an existing
  entry's deadline, and it saves a pointless round-trip besides.

This is the single concurrency primitive of the interface; `pop!`, `get!`, and
counters are all defined in terms of it.  Backends should override it with a
native atomic operation (a Redis `EVAL` script, a SQL `UPDATE ... RETURNING`
inside a transaction, a conditional write with an ETag).

!!! warning "Never mutate the value you were passed"
    Because `new === old` means "no change", mutating the passed value in place
    and returning it is **indistinguishable from returning it untouched** — the
    write is skipped, and on a serializing backend your mutation is silently
    lost (on `MemoryStore` it may appear to work, purely by reference aliasing).
    When you change anything, return a *new* object: `copy(old)` first, or build
    the replacement from scratch.  `f` may also run more than once on
    compare-and-swap backends, so keep it free of side effects.

!!! warning "Check [`isatomic`](@ref)"
    The fallback implementation is `lock(store) do; get; f; put!; end`, which is
    only as atomic as the store's `Base.lock(f, store)` method — by default, not
    at all.  A store that has not overridden either `modify!` or `Base.lock`
    reports `isatomic(store) == false`, and this fallback is then subject to lost
    updates under concurrency.

!!! note "A write replaces the expiry"
    Writing a *changed* value stores it with the `ttl` you pass to this call —
    and with no `ttl`, no expiry.  There is currently no way to say "keep the
    key's remaining deadline"; compute it yourself if you need that.

!!! note "`T === Nothing`"
    Because `nothing` signals deletion, a store whose `eltype` includes `Nothing`
    cannot write `nothing` through `modify!`.  Use `put!` for that case.

# Examples
```julia
# append to a bounded history list — note the `copy`: returning the object you
# were handed, mutated or not, means "no change"
modify!(store, "history/\$job") do old
    execs = old === nothing ? JobExecution[] : copy(old)
    pushfirst!(execs, execution)
    return length(execs) > 100 ? execs[1:100] : execs
end

# increment a counter
modify!(counters, "hits") do n
    n === nothing ? 1 : n + 1
end

# insert only if absent (returns the winning value either way)
modify!(store, key) do old
    old === nothing ? candidate : old
end
```
"""
function modify!(f, store::AbstractStore, key::AbstractString; ttl=nothing)
    checkttl(store, ttl)
    return lock(store) do
        old = get(store, key, nothing)
        new = f(old)
        new === old && return new       # unchanged: don't write, don't touch the expiry
        if new === nothing
            delete!(store, key)
        else
            put!(store, key, new; ttl)
        end
        return new
    end
end

"""
    lock(f::Function, store::AbstractStore)

Run `f` while holding `store`'s mutual-exclusion lock, if it has one.

The default implementation simply calls `f()` — **no locking**.  Stores backed by
process-local state should override this (and report
[`isatomic`](@ref)` == true`); stores backed by a remote service should instead
override [`modify!`](@ref) with a server-side atomic operation.
"""
Base.lock(f, ::AbstractStore) = f()

#-------------------------------------------------------------------------------
# Derived operations
#-------------------------------------------------------------------------------

"""
    store[key] -> value

Fetch the value stored under `key`, throwing `KeyError` if absent or expired.
Use `get(store, key, default)` to supply a fallback instead.
"""
function Base.getindex(store::AbstractStore, key::AbstractString)
    value = get(store, key, NOTFOUND)
    value === NOTFOUND && throw(KeyError(key))
    return value
end

"""
    store[key] = value

Shorthand for `put!(store, key, value)`.  Use [`put!`](@ref) directly when you
need a `ttl`.
"""
function Base.setindex!(store::AbstractStore, value, key::AbstractString)
    put!(store, key, value)
    return store
end

"""
    haskey(store::AbstractStore, key::AbstractString) -> Bool

Whether `key` is present and unexpired.

The fallback fetches the whole value; backends with a cheap existence check
(Redis `EXISTS`, S3 `HEAD`, `SELECT 1`) should override it.
"""
Base.haskey(store::AbstractStore, key::AbstractString) =
    get(store, key, NOTFOUND) !== NOTFOUND

"""
    pop!(store::AbstractStore{T}, key::AbstractString) -> T
    pop!(store::AbstractStore{T}, key::AbstractString, default) -> Union{T,typeof(default)}

Atomically remove `key` and return its value, or `default` if absent (the
two-argument form throws `KeyError`).

This is the "consume" / single-use primitive: exactly one caller can win the race
for a given key, which is what makes it the right operation for OAuth
authorization codes, one-time tokens, and work-queue claims — *provided*
[`isatomic`](@ref)`(store)` is `true`.
"""
function Base.pop!(store::AbstractStore, key::AbstractString, default)
    taken = Ref{Any}(NOTFOUND)
    modify!(store, key) do old
        taken[] = old === nothing ? NOTFOUND : old
        return nothing
    end
    return taken[] === NOTFOUND ? default : taken[]
end

function Base.pop!(store::AbstractStore, key::AbstractString)
    value = pop!(store, key, NOTFOUND)
    value === NOTFOUND && throw(KeyError(key))
    return value
end

"""
    get!(store::AbstractStore{T}, key::AbstractString, default; ttl=nothing) -> T
    get!(f::Function, store::AbstractStore{T}, key::AbstractString; ttl=nothing) -> T

Return the value stored under `key`, or atomically store and return `default`
(or `f()`) if it is absent.

With an [`isatomic`](@ref) store this is a "first writer wins" primitive: `f` may
run on several tasks, but every caller observes the same stored value.

A key that is already present is left completely alone — no write, and no change
to its expiry — which is what makes this usable for leases:

```julia
# true for exactly one caller, until the lease expires on its own
get!(leases, "nightly-report", myid; ttl=Dates.Minute(5)) == myid
```
"""
Base.get!(store::AbstractStore, key::AbstractString, default; ttl=nothing) =
    get!(() -> default, store, key; ttl)

function Base.get!(f, store::AbstractStore, key::AbstractString; ttl=nothing)
    return modify!(store, key; ttl) do old
        old === nothing ? f() : old
    end
end

"""
    length(store::AbstractStore) -> Int

Number of unexpired keys.  The fallback counts `keys(store)`, which for a remote
store is a full listing — prefer `isempty` or a targeted `haskey` in hot paths.
"""
Base.length(store::AbstractStore) = count(_ -> true, keys(store))

Base.isempty(store::AbstractStore) = iterate(keys(store)) === nothing

"""
    empty!(store::AbstractStore; prefix="") -> store

Delete every key in `store`, or every key starting with `prefix`.
"""
function Base.empty!(store::AbstractStore; prefix::AbstractString="")
    for key in collect(keys(store; prefix))
        delete!(store, key)
    end
    return store
end

"""
    pairs(store::AbstractStore{T}; prefix="") -> iterator of Pair{String,T}

Iterate `key => value` pairs.  Issues one `get` per key, so this is `N+1`
round-trips against a remote store; it is intended for small stores, debugging,
and tests.
"""
function Base.pairs(store::AbstractStore; prefix::AbstractString="")
    return (key => store[key] for key in keys(store; prefix))
end

"""
    sweep!(store::AbstractStore) -> Int

Physically reclaim expired entries, returning the number removed.

Expired entries are *always* invisible to `get`, `haskey`, and `keys` — this is
only about reclaiming space.  Backends with native expiry (Redis) need not
implement it; the default is a no-op returning `0`.
"""
sweep!(::AbstractStore) = 0

function Base.show(io::IO, store::AbstractStore)
    print(io, typeof(store), "(...)")
end
