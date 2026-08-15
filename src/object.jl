# ObjectStore: type and pure helpers. Methods live in
# `ext/AbstractStoresCloudStoreExt.jl`.

"""
    ObjectStore{T}(bucket; prefix="", codec=SerializedCodec(), credentials=nothing)

A store backed by cloud object storage — S3, Azure Blobs, or GCS — via
[CloudStore.jl](https://github.com/JuliaServices/CloudStore.jl).  `bucket` is an
`AWS.Bucket`, `Azure.Container`, or `GCP.Bucket`.

`credentials` is passed through to every CloudStore call, because a `Bucket` is
just a name and a URL — CloudBase carries credentials per request, not on the
handle.  Leave it `nothing` to let CloudStore resolve them from the environment,
instance metadata, or a config file as usual.

Every key becomes one object at `prefix * key`.  `prefix` is a field here rather
than a [`PrefixedStore`](@ref) wrapper because buckets are almost always shared,
and because `list` needs the prefix server-side to avoid enumerating the bucket.

- [`supportsttl`](@ref): `true` unless `codec` is [`RawCodec`](@ref).  Object
  stores have no per-object expiry, so the deadline rides along in the encoded
  [`Entry`](@ref) envelope and entries expire lazily on read; [`sweep!`](@ref)
  reclaims them.  For large stores, a bucket lifecycle rule is the cheaper tool.
- [`supportslisting`](@ref): `true`, via a prefix `list`
- [`isatomic`](@ref): **`false`** — see below

# Atomicity

Object storage gives no read-modify-write primitive that CloudStore.jl exposes,
so `modify!`, `pop!`, and `get!` fall back to a process-local lock.  Two processes
racing on the same key can lose an update, and two processes can both "win" the
same `pop!`.

Do not use this store for single-use tokens, leases, or counters.  It is the right
choice for durable, mostly-write-once state — cached discovery documents,
snapshots, per-tenant configuration — where last-writer-wins is fine.

!!! note "Requires CloudStore.jl"
    The methods live in a package extension; `using CloudStore` to enable them.

!!! warning "A few keys are not storable yet"
    Keys go into the request path verbatim, and CloudBase neither escapes a space
    nor canonicalizes an existing `%` for signing.  Keys containing a space or a
    `%`, or with a `.`/`..` path segment, are rejected up front by
    [`checkobjectkey`](@ref) rather than failing as an opaque 400/403.  Everything
    else — nested `a/b/c`, unicode, `+`, `&`, `#` — works.  This is a CloudBase
    limitation; the other backends handle arbitrary keys.

!!! note "Two different `AbstractStore`s"
    `CloudBase.jl` also defines a type named `AbstractStore` (the supertype of
    `Bucket`/`Container`).  It is unrelated to this package's
    [`AbstractStore`](@ref); if you load both, qualify the name.

# Examples
```julia
using AbstractStores, CloudStore, CloudBase.AWS

bucket = AWS.Bucket("my-app-state")
config = ObjectStore{Config}(bucket; prefix="tenants/", codec=JSONCodec())

config["acme"] = Config(...)
collect(keys(config))     # ["acme"]
```
"""
struct ObjectStore{T,C<:AbstractCodec,B,Cr} <: AbstractStore{T}
    bucket::B
    prefix::String
    codec::C
    credentials::Cr
    lock::ReentrantLock
end

function ObjectStore{T}(bucket; prefix::AbstractString="",
                        codec::AbstractCodec=SerializedCodec(),
                        credentials=nothing) where {T}
    extensionloaded(ObjectStore) || throw(ArgumentError(
        "ObjectStore requires CloudStore.jl: `using CloudStore` to load the " *
        "AbstractStoresCloudStoreExt extension."))
    return ObjectStore{T,typeof(codec),typeof(bucket),typeof(credentials)}(
        bucket, String(prefix), codec, credentials, ReentrantLock())
end

supportsttl(store::ObjectStore) = canexpire(store.codec)
supportslisting(::ObjectStore) = true
isatomic(::ObjectStore) = false

Base.lock(f, store::ObjectStore) = withstorelock(f, store.lock)

"""
    AbstractStores.checkobjectkey(key)

Throw an `ArgumentError` for a key CloudBase cannot currently transmit.

Object keys are opaque strings, not paths — `a/b/c` is one key, and the service
never resolves a `..` out of one, so nothing here needs escaping for safety.  What
does need care is the URL: CloudBase puts the key into the request path verbatim
and its SigV4 canonical URI does not agree with the server about percent-escapes,
so today a key is storable only if it survives that round trip untouched.

Empirically (against Minio, CloudBase 1.5.0 / CloudStore 1.6.4):

| key | result |
|:---|:---|
| `nested/key`, `plus+plus`, `amp&amp`, `hash#hash`, `unicode-ü` | fine |
| `with space` | 400 — the space is never escaped |
| `with%20space` | 403 — signature computed over a different canonical URI |
| `p/../escape`, `p/./dot` | 400 — the service rejects dot segments outright |

So the store validates rather than escapes.  Escaping *would* be the correct S3
behavior, but it would also break every key in the first row above, which works
today — so this is deliberately conservative until CloudBase's signing is fixed.
"""
function checkobjectkey(key::AbstractString)
    reason = if occursin(' ', key)
        "contains a space, which CloudBase does not escape (the service answers 400)"
    elseif occursin('%', key)
        "contains '%', which CloudBase's request signing does not canonicalize (403)"
    elseif any(seg -> seg == "." || seg == "..", split(key, '/'))
        "contains a '.' or '..' path segment, which object storage rejects (400)"
    else
        return nothing
    end
    throw(ArgumentError("object key $(repr(String(key))) $reason. " *
        "See `?AbstractStores.checkobjectkey`; this is a CloudBase limitation, " *
        "not an object-storage one."))
end

function objectkey(store::ObjectStore, key::AbstractString)
    checkobjectkey(key)
    return string(store.prefix, key)
end

Base.show(io::IO, store::ObjectStore{T}) where {T} =
    print(io, "ObjectStore{", T, "}(", store.bucket, ", prefix=", repr(store.prefix), ")")
