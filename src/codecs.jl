# Codecs: how a Julia value becomes bytes for stores that persist bytes.

"""
    AbstractStores.Entry{T}

The envelope a serializing store writes: a value plus its absolute UTC expiry
(`nothing` for "never").

Bundling the expiry *with* the value is what makes TTL work uniformly on
backends that have no native notion of it (files, object storage): entries expire
lazily on read, and [`sweep!`](@ref) reclaims them in bulk.  Backends with a real
expiry column or command (SQL, Redis) should encode the bare value instead and
let the server own the deadline.

# Fields
- `value::T`
- `expires::Union{Nothing,DateTime}` — absolute, UTC
"""
struct Entry{T}
    value::T
    expires::Union{Nothing,DateTime}
end

Entry(value::T) where {T} = Entry{T}(value, nothing)
isexpired(e::Entry, now::DateTime=Dates.now(UTC)) = isexpired(e.expires, now)

"""
    AbstractStores.AbstractCodec

Supertype for value serialization strategies.  A codec turns a `T` into bytes and
back, and is orthogonal to *where* those bytes live: the same codec works for
[`FileStore`](@ref), a SQL `BLOB` column, a Redis string, or an S3 object.

Implement two methods:

    AbstractStores.encode(codec, value)::Vector{UInt8}
    AbstractStores.decode(codec, ::Type{T}, bytes)::T

Built-in codecs: [`SerializedCodec`](@ref) (the default), [`RawCodec`](@ref),
and [`JSONCodec`](@ref) (requires `using JSON`).
"""
abstract type AbstractCodec end

"""
    AbstractStores.encode(codec, value) -> Vector{UInt8}

Serialize `value` with `codec`.  See [`AbstractCodec`](@ref).
"""
function encode(codec::AbstractCodec, value)
    codec isa JSONCodec && error(JSON_EXT_MISSING)
    throw(ArgumentError("$(typeof(codec)) does not implement `AbstractStores.encode`"))
end

"""
    AbstractStores.decode(codec, ::Type{T}, bytes) -> T

Deserialize `bytes` into a `T` with `codec`.  See [`AbstractCodec`](@ref).
"""
function decode(codec::AbstractCodec, ::Type{T}, bytes::AbstractVector{UInt8}) where {T}
    codec isa JSONCodec && error(JSON_EXT_MISSING)
    throw(ArgumentError("$(typeof(codec)) does not implement `AbstractStores.decode`"))
end

"""
    SerializedCodec()

Codec using Julia's `Serialization` stdlib.  The default: it handles essentially
any Julia value with no extra dependencies and no struct-mapping rules.

!!! warning "Not a portable format"
    `Serialization` makes no compatibility guarantees across Julia versions or
    across changes to your own struct definitions.  It is a fine choice for a
    cache or for state a single application version owns; use [`JSONCodec`](@ref)
    for anything you want to read from another process, another language, another
    Julia version, or a future release of your own package.
"""
struct SerializedCodec <: AbstractCodec end

function encode(::SerializedCodec, value)
    io = IOBuffer()
    Serialization.serialize(io, value)
    return take!(io)
end

decode(::SerializedCodec, ::Type{T}, bytes::AbstractVector{UInt8}) where {T} =
    Serialization.deserialize(IOBuffer(bytes))::T

"""
    RawCodec()

Identity codec for stores whose values are already bytes or text — that is,
`AbstractStore{Vector{UInt8}}` or `AbstractStore{String}`.  Nothing is wrapped,
escaped, or versioned, so the object in your bucket or the string in Redis is
exactly the value you put there.

Because it has nowhere to put an envelope, `RawCodec` cannot carry an expiry:
[`FileStore`](@ref) with a `RawCodec` reports `supportsttl == false`.  Backends
with server-side expiry (Redis, SQL) can still offer TTL with a `RawCodec`.
"""
struct RawCodec <: AbstractCodec end

encode(::RawCodec, value::AbstractVector{UInt8}) = convert(Vector{UInt8}, value)
encode(::RawCodec, value::AbstractString) = Vector{UInt8}(String(value))
encode(::RawCodec, value) = throw(ArgumentError(
    "RawCodec can only encode `AbstractString` or `AbstractVector{UInt8}` values, got $(typeof(value)). " *
    "Use `SerializedCodec()` or `JSONCodec()` for structured values."))

decode(::RawCodec, ::Type{Vector{UInt8}}, bytes::AbstractVector{UInt8}) = convert(Vector{UInt8}, bytes)
decode(::RawCodec, ::Type{String}, bytes::AbstractVector{UInt8}) = String(copy(convert(Vector{UInt8}, bytes)))
decode(::RawCodec, ::Type{T}, bytes::AbstractVector{UInt8}) where {T} = throw(ArgumentError(
    "RawCodec can only decode `String` or `Vector{UInt8}` values, got $T. " *
    "Use `SerializedCodec()` or `JSONCodec()` for structured values."))

"""
    JSONCodec()

Codec producing human-readable, portable JSON via
[JSON.jl](https://github.com/JuliaIO/JSON.jl).

Values round-trip through `JSON.json` / `JSON.parse(bytes, T)`, so any type
JSON.jl and StructUtils.jl can map — plain structs, `@kwdef` types, `Dict`s,
arrays, numbers, strings, `DateTime` — works without extra glue.

Prefer this over [`SerializedCodec`](@ref) for state that outlives a single
version of your program: config, refresh tokens, scheduled jobs, anything an
operator might want to inspect with `cat`.

!!! note "Requires JSON.jl"
    The methods live in a package extension.  `using JSON` (v1) alongside
    `AbstractStores` to enable them; without it, encoding throws with this
    instruction.
"""
struct JSONCodec <: AbstractCodec end

const JSON_EXT_MISSING = "JSONCodec requires JSON.jl v1: add it to your project and " *
    "`using JSON` to load the `AbstractStoresJSONExt` extension."

# NB: no `encode(::JSONCodec, ...)` method here on purpose. The extension defines
# it, and a same-signature stub in the parent would be a method *overwrite*, which
# Julia rejects during precompilation. The `AbstractCodec` fallback above carries
# the helpful message instead, and the extension's method is strictly more specific.

#-------------------------------------------------------------------------------
# Envelope encoding
#-------------------------------------------------------------------------------

"""
    AbstractStores.encodeentry(codec, entry::Entry) -> Vector{UInt8}
    AbstractStores.decodeentry(codec, ::Type{T}, bytes) -> Entry{T}

Encode/decode a value together with its expiry, for backends that must carry the
deadline in-band.  See [`Entry`](@ref).

`RawCodec` deliberately has no envelope form: it exists precisely so the stored
bytes are the value and nothing else.
"""
encodeentry(codec::AbstractCodec, entry::Entry) = encode(codec, entry)
decodeentry(codec::AbstractCodec, ::Type{T}, bytes::AbstractVector{UInt8}) where {T} =
    decode(codec, Entry{T}, bytes)

encodeentry(::RawCodec, entry::Entry) = throw(ArgumentError(
    "RawCodec stores values verbatim and cannot carry an expiry envelope"))
decodeentry(::RawCodec, ::Type{T}, ::AbstractVector{UInt8}) where {T} = throw(ArgumentError(
    "RawCodec stores values verbatim and cannot carry an expiry envelope"))

"""
    AbstractStores.canexpire(codec) -> Bool

Whether `codec` can carry an [`Entry`](@ref) envelope, and therefore whether a
store that relies on in-band expiry can offer TTL with this codec.
"""
canexpire(::AbstractCodec) = true
canexpire(::RawCodec) = false
