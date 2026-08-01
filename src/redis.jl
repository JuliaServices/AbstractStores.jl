# RedisStore: type and pure helpers. Methods live in `ext/AbstractStoresRedisExt.jl`.

"""
    RedisStore{T}(client; codec=SerializedCodec())

A store backed by Redis, over a `Redis.Client` from
[Redis.jl](https://github.com/JuliaServices/Redis.jl).

- [`supportsttl`](@ref): `true` — native `SET ... PX`, so Redis reclaims memory
  itself and [`sweep!`](@ref) is a no-op
- [`supportslisting`](@ref): `true` — `keys(store; prefix=...)` uses `SCAN MATCH`,
  which is incremental and therefore only eventually consistent
- [`isatomic`](@ref): `true` — `modify!` is a compare-and-swap `EVAL` script (see
  below), so single-use tokens and counters are safe across processes

# Storage format

Each value is stored as a 16-hex-character compare-and-swap token followed by the
base64 of the codec's bytes.  Base64 keeps values in the ASCII range, which keeps
the RESP command builder honest about byte lengths regardless of what the codec
produced.

# Atomicity

`modify!` reads the current value and its token, applies `f`, then runs a small
Lua script that writes only if the token is unchanged, retrying on conflict up to
[`MAX_CAS_ATTEMPTS`](@ref) times.  A token rather than the value itself is
compared, so an A→B→A sequence between the read and the write is correctly
detected as a conflict.

!!! warning "`f` may run more than once"
    Inherent to compare-and-swap — keep the callback pure.

!!! warning "An unprefixed store owns the whole database"
    `keys(store)` scans, and `empty!(store)` deletes, every key in the connected
    Redis database.  Wrap the store in a [`PrefixedStore`](@ref) (or point the
    client at a dedicated `db` index) unless that is what you want.

!!! note "Requires the JuliaServices Redis.jl (not yet registered)"
    The methods live in `ext/AbstractStoresRedisExt.jl`, which targets
    [JuliaServices/Redis.jl](https://github.com/JuliaServices/Redis.jl) — a
    different package from any `Redis.jl` in General.  Because that package is
    not registered yet, the extension is *not declared* in `Project.toml` (a
    registered package cannot reference an unregistered weakdep); it will be
    declared the moment Redis.jl is registered.  Until then:
    `Pkg.develop` Redis.jl, then
    `include(joinpath(pkgdir(AbstractStores), "ext", "AbstractStoresRedisExt.jl"))`.

# Examples
```julia
using AbstractStores, Redis
# until Redis.jl is registered, load the extension by hand:
include(joinpath(pkgdir(AbstractStores), "ext", "AbstractStoresRedisExt.jl"))

client = Redis.connect("localhost", 6379)
codes = PrefixedStore(RedisStore{String}(client), "oauth:code:")

put!(codes, code, grant; ttl=Dates.Second(60))
pop!(codes, code, nothing)     # exactly one process wins
```
"""
struct RedisStore{T,C<:AbstractCodec,Client} <: AbstractStore{T}
    client::Client
    codec::C
    # SHA of the CAS script once SCRIPT LOADed on this client; "" until then.
    # A racing double-load is harmless (same script, same sha).
    scriptsha::Base.RefValue{String}
end

function RedisStore{T}(client; codec::AbstractCodec=SerializedCodec()) where {T}
    extensionloaded(RedisStore) || throw(ArgumentError(
        "RedisStore requires the JuliaServices Redis.jl " *
        "(https://github.com/JuliaServices/Redis.jl), which is not registered in " *
        "General yet, so its package extension is not declared. Until it is: " *
        "`Pkg.develop` Redis.jl, `using Redis`, then " *
        "`include(joinpath(pkgdir(AbstractStores), \"ext\", \"AbstractStoresRedisExt.jl\"))`."))
    return RedisStore{T,typeof(codec),typeof(client)}(client, codec, Ref(""))
end

supportsttl(::RedisStore) = true
supportslisting(::RedisStore) = true
isatomic(::RedisStore) = true

"Number of leading hex characters of a Redis value that hold its CAS token."
const TOKEN_CHARS = 16

newtoken() = string(rand(UInt64); base=16, pad=TOKEN_CHARS)

# value on the wire is `<token><base64 payload>`
function redisencode(store::RedisStore{T}, value) where {T}
    token = newtoken()
    return token, token * Base64.base64encode(encode(store.codec, convert(T, value)))
end

redisdecode(store::RedisStore{T}, raw::AbstractString) where {T} =
    decode(store.codec, T, Base64.base64decode(SubString(raw, TOKEN_CHARS + 1)))

redistoken(raw::AbstractString) = String(SubString(raw, 1, TOKEN_CHARS))

"""
    AbstractStores.globescape(s) -> String

Escape the characters Redis treats as glob metacharacters (`*`, `?`, `[`, `]`,
`\\`) so a key prefix can be used literally in a `SCAN MATCH` pattern.
"""
function globescape(s::AbstractString)
    io = IOBuffer()
    for c in s
        (c == '*' || c == '?' || c == '[' || c == ']' || c == '\\') && write(io, '\\')
        write(io, c)
    end
    return String(take!(io))
end

Base.show(io::IO, store::RedisStore{T}) where {T} =
    print(io, "RedisStore{", T, "}(", store.client, ")")
