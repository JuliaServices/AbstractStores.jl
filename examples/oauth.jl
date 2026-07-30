# How OAuth.jl would swap its three store hierarchies for AbstractStores.
#
# OAuth.jl currently defines three separate abstract types, each with its own
# in-memory implementation, its own operations, and (for refresh tokens) a
# hand-written file backend with locking, permissions, and a versioned base64
# envelope — roughly 300 lines of `src/types.jl` and `src/server.jl`:
#
#   abstract type RefreshTokenStore end
#       InMemoryRefreshTokenStore, FileBasedRefreshTokenStore, CallbackRefreshTokenStore
#       load_refresh_token / save_refresh_token! / clear_refresh_token!
#       load_token_response / save_token_response!
#   abstract type AccessTokenStore end
#       InMemoryTokenStore
#       store_access_token! / lookup_access_token / revoke_access_token!
#   abstract type AuthorizationCodeStore end
#       InMemoryAuthorizationCodeStore
#       store_authorization_code! / consume_authorization_code!
#
# All three are key-value stores with expiry. This file shows them as one.

module OAuthStores

using Dates, AbstractStores

# ---------------------------------------------------------------------------
# Stand-ins for the OAuth.jl types, so this example runs on its own.
# ---------------------------------------------------------------------------

struct TokenResponse
    access_token::String
    refresh_token::Union{Nothing,String}
    expires_in::Int
end

struct AccessTokenRecord
    token::String
    scope::Vector{String}
    issued_at::DateTime
    expires_at::DateTime
    client_id::Union{String,Nothing}
    subject::Union{String,Nothing}
    revoked::Bool
end

struct AuthorizationCodeRecord
    code::String
    client_id::String
    redirect_uri::String
    scope::Vector{String}
    subject::Union{String,Nothing}
    code_challenge::Union{String,Nothing}
    issued_at::DateTime
    expires_at::DateTime
end

struct ClientConfig
    issuer::String
    client_id::String
end

# ---------------------------------------------------------------------------
# 1. Refresh tokens
#
# Before: `load_refresh_token(store, config)` with the store holding exactly one
# token, so a `FileBasedRefreshTokenStore` was one file per account.
#
# After: an `AbstractStore{TokenResponse}` keyed by the config it belongs to.
# Multi-account support falls out for free, and `FileBasedRefreshTokenStore` —
# tempfile-and-rename, 0o600, JSON envelope, stale lock reaping — is just
# `FileStore`, which already does all of that.
# ---------------------------------------------------------------------------

refresh_key(cfg::ClientConfig) = string(cfg.issuer, '|', cfg.client_id)

load_refresh_token(store::AbstractStore, cfg::ClientConfig) =
    get(store, refresh_key(cfg), nothing)

save_refresh_token!(store::AbstractStore, cfg::ClientConfig, token::TokenResponse) =
    (put!(store, refresh_key(cfg), token); nothing)

clear_refresh_token!(store::AbstractStore, cfg::ClientConfig) =
    (delete!(store, refresh_key(cfg)); nothing)

# `CallbackRefreshTokenStore(; load, save, clear)` existed as the escape hatch for
# "bring your own persistence". The interface *is* the escape hatch now: implement
# four methods on your own type and every OAuth store accepts it. Users who want a
# keychain, a secrets manager, or a database write a store once and use it for
# refresh tokens, access tokens, and authorization codes alike.

# ---------------------------------------------------------------------------
# 2. Access tokens
#
# Before: `InMemoryTokenStore` held a `Dict` and compared `expires_at` by hand at
# every lookup — and only in memory, so a second server process could not
# introspect a token the first one issued.
#
# After: expiry is the store's job, and the same three lines work against Redis
# or Postgres for a multi-process deployment.
# ---------------------------------------------------------------------------

function store_access_token!(store::AbstractStore, record::AccessTokenRecord;
                             now::DateTime=Dates.now(UTC))
    ttl = record.expires_at - now
    ttl > Millisecond(0) || throw(ArgumentError("access token already expired"))
    put!(store, record.token, record; ttl)
    return record
end

lookup_access_token(store::AbstractStore, token::AbstractString) =
    get(store, token, nothing)

revoke_access_token!(store::AbstractStore, token::AbstractString) =
    (delete!(store, token); nothing)

# ---------------------------------------------------------------------------
# 3. Authorization codes
#
# This is the case that most wants the interface. An authorization code is
# single-use and short-lived: RFC 6749 §4.1.2 requires the server to reject a
# code that has already been redeemed, and to expire it quickly.
#
# `consume_authorization_code!` is exactly `pop!`, and the TTL is exactly `ttl`.
# The security property "at most one redemption" then depends on
# `AbstractStores.isatomic(store)` — which is `true` for MemoryStore in one
# process, and true for SQLStore and RedisStore *across* processes. The old
# in-memory-only store could not offer that at all behind a load balancer.
# ---------------------------------------------------------------------------

store_authorization_code!(store::AbstractStore, record::AuthorizationCodeRecord;
                          ttl=Dates.Second(60)) =
    (put!(store, record.code, record; ttl); record)

consume_authorization_code!(store::AbstractStore, code::AbstractString) =
    pop!(store, code, nothing)

"""
    check_single_use(store)

Refuse to run an authorization-code flow on a store that cannot guarantee
single-use redemption.  Worth calling at server construction: it turns a silent
security weakness into a startup error.
"""
function check_single_use(store::AbstractStore)
    AbstractStores.isatomic(store) || throw(ArgumentError(
        "authorization codes require an atomic store (got $(typeof(store))); " *
        "`AbstractStores.isatomic` is false, so two concurrent redemptions of the " *
        "same code could both succeed"))
    AbstractStores.supportsttl(store) || throw(ArgumentError(
        "authorization codes require a store supporting `ttl` (got $(typeof(store)))"))
    return store
end

# ---------------------------------------------------------------------------
# Wiring it together
# ---------------------------------------------------------------------------

"""
    server_stores(backend)

All three OAuth stores over one backend, namespaced apart.  The application picks
the backend; OAuth.jl never needs to know which one.
"""
function server_stores(backend::AbstractStore)
    return (refresh = PrefixedStore{TokenResponse}(backend, "oauth/refresh/"),
            access = PrefixedStore{AccessTokenRecord}(backend, "oauth/access/"),
            codes = check_single_use(PrefixedStore{AuthorizationCodeRecord}(backend, "oauth/code/")))
end

end # module
