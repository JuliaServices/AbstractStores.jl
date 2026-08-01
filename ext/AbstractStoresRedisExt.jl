module AbstractStoresRedisExt

using Redis
using AbstractStores
using AbstractStores: AbstractStores, RedisStore, PrefixedStore, ConcurrencyError,
    MAX_CAS_ATTEMPTS, TOKEN_CHARS, redisencode, redisdecode, redistoken, globescape,
    newtoken, ttlseconds, checkttl

AbstractStores.extensionloaded(::Type{<:RedisStore}) = true

# Build a raw RESP command for the handful of verbs Redis.jl does not wrap.
# `Redis.Commands.Command{T}` is just a RESP string plus the expected reply type.
function rawcommand(::Type{T}, args::AbstractString...) where {T}
    io = IOBuffer()
    print(io, '*', length(args), "\r\n")
    for a in args
        print(io, '$', sizeof(a), "\r\n", a, "\r\n")
    end
    return Redis.Commands.Command{T}(String(take!(io)))
end

# Compare-and-swap: write only if the stored value still carries `token`.
# ARGV[1] = expected token ("" if the key should be absent)
# ARGV[2] = new value, or "-" to delete (a real value always starts with 16 hex
#           characters, so it can never collide with the sentinel)
# ARGV[3] = expiry in milliseconds, or 0 for none
const CAS_SCRIPT = """
local cur = redis.call('GET', KEYS[1])
local curtok = ''
if cur then curtok = string.sub(cur, 1, $TOKEN_CHARS) end
if curtok ~= ARGV[1] then return 0 end
if ARGV[2] == '-' then
  redis.call('DEL', KEYS[1])
else
  local px = tonumber(ARGV[3])
  if px > 0 then
    redis.call('SET', KEYS[1], ARGV[2], 'PX', px)
  else
    redis.call('SET', KEYS[1], ARGV[2])
  end
end
return 1
"""

function Base.get(store::RedisStore, key::AbstractString, default)
    raw = Redis.get(store.client, String(key))
    raw === nothing && return default
    return redisdecode(store, raw)
end

function Base.put!(store::RedisStore, key::AbstractString, value; ttl=nothing)
    _, payload = redisencode(store, value)
    secs = ttlseconds(ttl)
    if secs === nothing
        Redis.set(store.client, String(key), payload)
    else
        Redis.set(store.client, String(key), payload; px=round(Int, secs * 1000))
    end
    return store
end

function Base.delete!(store::RedisStore, key::AbstractString)
    Redis.del(store.client, String(key))
    return store
end

Base.haskey(store::RedisStore, key::AbstractString) =
    Redis.execute(store.client, rawcommand(Int, "EXISTS", String(key))) > 0

Base.keys(store::RedisStore; prefix::AbstractString="") =
    String[k for k in Redis.Scan(store.client, globescape(prefix) * "*")]

function Base.empty!(store::RedisStore; prefix::AbstractString="")
    for key in keys(store; prefix)
        Redis.del(store.client, key)
    end
    return store
end

# Redis expires keys itself; nothing to reclaim.
AbstractStores.sweep!(::RedisStore) = 0

# Run the CAS script by SHA, loading it at most once per *store* (stores
# sharing a client each load it once; the load is idempotent). If the server
# has lost it (SCRIPT FLUSH, restart), fall back to a plain EVAL for this call
# and reload on the next.
function evalcas(store::RedisStore, args::AbstractString...)
    sha = store.scriptsha[]
    if isempty(sha)
        sha = Redis.execute(store.client, rawcommand(String, "SCRIPT", "LOAD", CAS_SCRIPT))
        store.scriptsha[] = sha
    end
    try
        return Redis.execute(store.client, rawcommand(Int, "EVALSHA", sha, args...))
    catch e
        occursin("NOSCRIPT", sprint(showerror, e)) || rethrow()
        store.scriptsha[] = ""
        return Redis.execute(store.client, rawcommand(Int, "EVAL", CAS_SCRIPT, args...))
    end
end

function AbstractStores.modify!(f, store::RedisStore, key::AbstractString; ttl=nothing)
    k = String(key)
    secs = ttlseconds(ttl)
    px = string(secs === nothing ? 0 : round(Int, secs * 1000))
    for _ in 1:MAX_CAS_ATTEMPTS
        raw = Redis.get(store.client, k)
        old = raw === nothing ? nothing : redisdecode(store, raw)
        token = raw === nothing ? "" : redistoken(raw)
        new = f(old)
        new === old && return new       # unchanged: don't write, don't touch the expiry
        payload = new === nothing ? "-" : redisencode(store, new)[2]
        evalcas(store, "1", k, token, payload, px) == 1 && return new
    end
    throw(ConcurrencyError(k, MAX_CAS_ATTEMPTS))
end

end # module
