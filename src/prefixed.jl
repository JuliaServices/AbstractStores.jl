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

The two-argument form reuses the parent's `eltype`.  The parameterized form
narrows the view's type — but the *parent* still performs the decoding, so this
only round-trips when the parent preserves types: `MemoryStore` (values held by
reference) or any store using `SerializedCodec`.

!!! warning "Typed views require a type-preserving parent"
    `PrefixedStore{Job}(FileStore{Any}(dir; codec=JSONCodec()), "jobs/")` does
    **not** give you `Job`s back — JSON is decoded at the parent's `eltype`
    (`Any`), so values come back as `Dict{String,Any}`.  With a portable codec
    like `JSONCodec`, give each kind of state its own concretely-typed store
    (same backend, different directory/table/prefix) instead of typed views over
    one `Any` store.

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
