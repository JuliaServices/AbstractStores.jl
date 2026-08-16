"""
    PrefixedStore(parent::AbstractStore, prefix::AbstractString)
    PrefixedStore{T}(parent::AbstractStore, prefix::AbstractString)

A view of `parent` in which every key is transparently prefixed with `prefix`.

This is how several logically separate stores share one backend: a library that
needs three kinds of state does not need three Redis connections or three
directories, and an application embedding several such libraries can keep their
keys from colliding.

Every operation except `sweep!` is scoped to the prefix — `empty!` on a
`PrefixedStore` will not touch a sibling's keys, while `sweep!` reclaims expired
entries across the whole parent (reclamation has no reason to stop at a
namespace boundary).  All traits are inherited from `parent`.

The two-argument form reuses the parent's `eltype`. The parameterized form
narrows the view's type and forwards that type through nested views. `FileStore`
uses the requested type for its codec, so a `PrefixedStore{Job}` over a
`FileStore{Any}` can encode and decode `Job` values directly, including with
`JSONCodec`. Other backends may treat their own `eltype` as authoritative; use a
concretely typed parent when its documentation does not promise typed decoding.

# Examples
```julia
backend = MemoryStore{String}()

tokens = PrefixedStore(backend, "oauth/refresh/")
codes  = PrefixedStore(backend, "oauth/code/")

tokens["alice"] = "rt_abc"
codes["xyz"]    = "grant"

collect(keys(tokens))    # ["alice"]
empty!(codes)            # leaves tokens alone
collect(keys(tokens))    # ["alice"]
```
"""
struct PrefixedStore{T,S<:AbstractStore} <: AbstractStore{T}
    parent::S
    prefix::String
end

PrefixedStore(parent::AbstractStore{T}, prefix::AbstractString) where {T} =
    PrefixedStore{T,typeof(parent)}(parent, String(prefix))
PrefixedStore{T}(parent::AbstractStore, prefix::AbstractString) where {T} =
    PrefixedStore{T,typeof(parent)}(parent, String(prefix))

supportsttl(store::PrefixedStore) = supportsttl(store.parent)
supportslisting(store::PrefixedStore) = supportslisting(store.parent)
isatomic(store::PrefixedStore) = isatomic(store.parent)

Base.lock(f, store::PrefixedStore) = lock(f, store.parent)

full(store::PrefixedStore, key::AbstractString) = string(store.prefix, key)

# A typed view forwards its own value type to the backend, so a
# value-erased parent (`FileStore{Any}`) still encodes and decodes each
# record as the view's concrete `T` — keeping the codec statically typed.
Base.get(store::PrefixedStore{T}, key::AbstractString, default) where {T} =
    get(T, store, key, default)

Base.get(::Type{T}, store::PrefixedStore, key::AbstractString, default) where {T} =
    get(T, store.parent, full(store, key), default)

Base.put!(store::PrefixedStore{T}, key::AbstractString, value; ttl=nothing) where {T} =
    put!(T, store, key, value; ttl)

function Base.put!(::Type{T}, store::PrefixedStore, key::AbstractString, value; ttl=nothing) where {T}
    put!(T, store.parent, full(store, key), value; ttl)
    return store
end

function Base.delete!(store::PrefixedStore, key::AbstractString)
    delete!(store.parent, full(store, key))
    return store
end

Base.haskey(store::PrefixedStore, key::AbstractString) =
    haskey(store.parent, full(store, key))

Base.keys(store::PrefixedStore{T}; prefix::AbstractString="") where {T} =
    keys(T, store; prefix)

function Base.keys(::Type{T}, store::PrefixedStore; prefix::AbstractString="") where {T}
    n = ncodeunits(store.prefix)
    # every key came back with `store.prefix` attached, so byte n+1 starts the suffix
    return [k[n+1:end] for k in keys(T, store.parent; prefix=full(store, prefix))]
end

Base.empty!(store::PrefixedStore; prefix::AbstractString="") =
    (empty!(store.parent; prefix=full(store, prefix)); store)

# forward to the parent so a native atomic implementation is not lost
# Forwarded WITH the view's value type: backends with a native atomic
# read-modify-write (Redis, SQL) keep their own modify!, while the generic
# lock+get+put! loop on file/memory backends round-trips through the typed
# entry points so the codec sees the view's concrete T.
modify!(f, store::PrefixedStore{T}, key::AbstractString; ttl=nothing) where {T} =
    modify!(T, f, store, key; ttl)

modify!(::Type{T}, f, store::PrefixedStore, key::AbstractString; ttl=nothing) where {T} =
    modify!(T, f, store.parent, full(store, key); ttl)

sweep!(store::PrefixedStore) = sweep!(store.parent)

Base.show(io::IO, store::PrefixedStore{T}) where {T} =
    print(io, "PrefixedStore{", T, "}(", store.parent, ", ", repr(store.prefix), ")")
