module AbstractStoresCloudStoreExt

using Dates
using CloudStore
using AbstractStores
using AbstractStores: AbstractStores, ObjectStore, Entry, objectkey, canexpire,
    encode, decode, encodeentry, decodeentry, expiryof, checkttl, isexpired

AbstractStores.extensionloaded(::Type{<:ObjectStore}) = true

# A missing object surfaces as an HTTP 404 from somewhere inside the request
# stack; unwrap far enough to recognize it without depending on HTTP.jl.
function is404(e)
    for _ in 1:8
        hasproperty(e, :status) && return getproperty(e, :status) == 404
        if hasproperty(e, :error)
            e = getproperty(e, :error)
        elseif hasproperty(e, :captured)
            e = getproperty(e, :captured).ex
        else
            return false
        end
    end
    return false
end

function readbytes(store::ObjectStore, key::AbstractString)
    try
        return CloudStore.get(store.bucket, objectkey(store, key); credentials=store.credentials)
    catch e
        is404(e) && return nothing
        rethrow()
    end
end

function readentry(store::ObjectStore{T}, key::AbstractString) where {T}
    bytes = readbytes(store, key)
    bytes === nothing && return nothing
    return canexpire(store.codec) ? decodeentry(store.codec, T, bytes) :
           Entry{T}(decode(store.codec, T, bytes), nothing)
end

function Base.get(store::ObjectStore, key::AbstractString, default)
    entry = readentry(store, key)
    entry === nothing && return default
    if isexpired(entry)
        # best-effort reclamation: reading must not require delete permission
        try delete!(store, key) catch end
        return default
    end
    return entry.value
end

function Base.put!(store::ObjectStore{T}, key::AbstractString, value; ttl=nothing) where {T}
    checkttl(store, ttl)
    typed = convert(T, value)
    bytes = canexpire(store.codec) ?
        encodeentry(store.codec, Entry{T}(typed, expiryof(ttl))) :
        encode(store.codec, typed)
    CloudStore.put(store.bucket, objectkey(store, key), bytes; credentials=store.credentials)
    return store
end

function Base.delete!(store::ObjectStore, key::AbstractString)
    try
        CloudStore.delete(store.bucket, objectkey(store, key); credentials=store.credentials)
    catch e
        is404(e) || rethrow()
    end
    return store
end

function Base.haskey(store::ObjectStore, key::AbstractString)
    canexpire(store.codec) && return get(store, key, nothing) !== nothing
    try
        CloudStore.head(store.bucket, objectkey(store, key); credentials=store.credentials)
        return true
    catch e
        is404(e) && return false
        rethrow()
    end
end

"""
    keys(store::ObjectStore; prefix="")

List keys via a server-side prefix `list`.

When the codec carries an expiry envelope this then reads every listed object to
drop expired ones, because object storage has no per-object deadline to filter
on — `n` objects cost `n` GETs.  With a `RawCodec` it is a single `list`.
"""
function Base.keys(store::ObjectStore; prefix::AbstractString="")
    objects = CloudStore.list(store.bucket; prefix=objectkey(store, prefix), credentials=store.credentials)
    n = ncodeunits(store.prefix)
    result = String[]
    now = Dates.now(UTC)
    for obj in objects
        key = obj.key[n+1:end]
        if canexpire(store.codec)
            entry = readentry(store, key)
            (entry === nothing || isexpired(entry, now)) && continue
        end
        push!(result, key)
    end
    return result
end

function AbstractStores.sweep!(store::ObjectStore{T}) where {T}
    canexpire(store.codec) || return 0
    objects = CloudStore.list(store.bucket; prefix=store.prefix, credentials=store.credentials)
    n = ncodeunits(store.prefix)
    now = Dates.now(UTC)
    removed = 0
    for obj in objects
        key = obj.key[n+1:end]
        entry = readentry(store, key)
        if entry !== nothing && isexpired(entry, now)
            delete!(store, key)
            removed += 1
        end
    end
    return removed
end

end # module
