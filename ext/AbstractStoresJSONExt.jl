module AbstractStoresJSONExt

using JSON
using AbstractStores: AbstractStores, JSONCodec

AbstractStores.encode(::JSONCodec, value) = Vector{UInt8}(JSON.json(value))

AbstractStores.decode(::JSONCodec, ::Type{T}, bytes::AbstractVector{UInt8}) where {T} =
    JSON.parse(bytes, T)

# `Entry{T}` is a plain struct with a `Union{Nothing,DateTime}` field, which
# JSON.jl/StructUtils round-trip directly — no special handling needed, so the
# generic `encodeentry`/`decodeentry` fallbacks in the core do the right thing.

end # module
