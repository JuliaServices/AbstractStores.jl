"""
    PrefixedStore(parent::AbstractStore, prefix::AbstractString)
    PrefixedStore{T}(parent::AbstractStore, prefix::AbstractString)

A view of `parent` in which every key is transparently prefixed with `prefix`.

This is how several logically separate stores share one backend: a library that
needs three kinds of state does not need three Redis connections or three
directories, and an application embedding several such libraries can keep their
keys from colliding.

Every operation, including `keys`, `length`, `empty!`, and `sweep!`, is scoped to
the prefix — `empty!` on a `PrefixedStore` will not touch a sibling's keys.  All
traits are inherited from `parent`.

The two-argument form reuses the parent's `eltype`; the parameterized form lets a
single heterogeneous parent (say, an `AbstractStore{Vector{UInt8}}`) be viewed at
a narrower type where the codec supports it.

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

Base.get(store::PrefixedStore, key::AbstractString, default) =
    get(store.parent, full(store, key), default)

function Base.put!(store::PrefixedStore, key::AbstractString, value; ttl=nothing)
    put!(store.parent, full(store, key), value; ttl)
    return store
end

function Base.delete!(store::PrefixedStore, key::AbstractString)
    delete!(store.parent, full(store, key))
    return store
end

Base.haskey(store::PrefixedStore, key::AbstractString) =
    haskey(store.parent, full(store, key))

function Base.keys(store::PrefixedStore; prefix::AbstractString="")
    n = ncodeunits(store.prefix)
    # every key came back with `store.prefix` attached, so byte n+1 starts the suffix
    return [k[n+1:end] for k in keys(store.parent; prefix=full(store, prefix))]
end

Base.empty!(store::PrefixedStore; prefix::AbstractString="") =
    (empty!(store.parent; prefix=full(store, prefix)); store)

# forward to the parent so a native atomic implementation is not lost
modify!(f, store::PrefixedStore, key::AbstractString; ttl=nothing) =
    modify!(f, store.parent, full(store, key); ttl)

sweep!(store::PrefixedStore) = sweep!(store.parent)

Base.show(io::IO, store::PrefixedStore{T}) where {T} =
    print(io, "PrefixedStore{", T, "}(", store.parent, ", ", repr(store.prefix), ")")
