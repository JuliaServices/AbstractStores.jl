"""
    MemoryStore{T}()
    MemoryStore()          # T === Any

A thread-safe, process-local store backed by a `Dict`, with full TTL support.

The reference implementation of the interface, and the right default for tests,
CLI tools, and single-process services that do not need to survive a restart.

- [`supportsttl`](@ref): `true` (expiry is checked lazily on read; [`sweep!`](@ref) reclaims eagerly)
- [`supportslisting`](@ref): `true`
- [`isatomic`](@ref): `true` — every operation takes the store's `ReentrantLock`,
  so `modify!`, `pop!`, and `get!` are safe across tasks and threads

!!! note "Values are stored by reference"
    Unlike serializing stores, `MemoryStore` keeps the value object itself.
    Mutating a value you fetched mutates what is in the store, and a `FileStore`
    would not behave that way.  Treat stored values as immutable if you want your
    code to work against any backend.

# Examples
```julia
julia> store = MemoryStore{Int}();

julia> store["hits"] = 1;

julia> modify!(store, "hits") do n
           n === nothing ? 1 : n + 1
       end
2

julia> put!(store, "otp", 123456; ttl=Dates.Second(30));

julia> pop!(store, "otp", nothing)   # single-use
123456
```
"""
struct MemoryStore{T} <: AbstractStore{T}
    lock::ReentrantLock
    data::Dict{String,Entry{T}}
end

MemoryStore{T}() where {T} = MemoryStore{T}(ReentrantLock(), Dict{String,Entry{T}}())
MemoryStore() = MemoryStore{Any}()

supportsttl(::MemoryStore) = true
supportslisting(::MemoryStore) = true
isatomic(::MemoryStore) = true

Base.lock(f, store::MemoryStore) = lock(f, store.lock)

function Base.get(store::MemoryStore, key::AbstractString, default)
    return @lock store.lock begin
        entry = Base.get(store.data, String(key), nothing)
        if entry === nothing
            default
        elseif isexpired(entry)
            delete!(store.data, String(key))
            default
        else
            entry.value
        end
    end
end

function Base.put!(store::MemoryStore{T}, key::AbstractString, value; ttl=nothing) where {T}
    @lock store.lock store.data[String(key)] = Entry{T}(convert(T, value), expiryof(ttl))
    return store
end

function Base.delete!(store::MemoryStore, key::AbstractString)
    @lock store.lock delete!(store.data, String(key))
    return store
end

function Base.haskey(store::MemoryStore, key::AbstractString)
    return @lock store.lock begin
        entry = Base.get(store.data, String(key), nothing)
        entry !== nothing && !isexpired(entry)
    end
end

function Base.keys(store::MemoryStore; prefix::AbstractString="")
    now = Dates.now(UTC)
    return @lock store.lock [k for (k, e) in store.data
                             if startswith(k, prefix) && !isexpired(e, now)]
end

Base.length(store::MemoryStore) = length(keys(store))

function Base.empty!(store::MemoryStore; prefix::AbstractString="")
    @lock store.lock begin
        if isempty(prefix)
            empty!(store.data)
        else
            for k in collect(Base.keys(store.data))
                startswith(k, prefix) && delete!(store.data, k)
            end
        end
    end
    return store
end

function sweep!(store::MemoryStore)
    now = Dates.now(UTC)
    return @lock store.lock begin
        expired = [k for (k, e) in store.data if isexpired(e, now)]
        for k in expired
            delete!(store.data, k)
        end
        length(expired)
    end
end

Base.show(io::IO, store::MemoryStore{T}) where {T} =
    print(io, "MemoryStore{", T, "}(", length(store), " keys)")
