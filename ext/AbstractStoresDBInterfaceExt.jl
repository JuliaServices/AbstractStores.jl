module AbstractStoresDBInterfaceExt

# Everything here talks to a database; the `SQLStore` type, its dialects, and the
# pure helpers live in `src/sql.jl` so that `AbstractStores.SQLStore` resolves
# whether or not this extension has been loaded.

using DBInterface
using AbstractStores
using AbstractStores: AbstractStores, SQLStore, ConcurrencyError, MAX_CAS_ATTEMPTS,
    placeholder, placeholders, likeprefix, unixms, nowms,
    encodevalue, decodevalue, expiryof

AbstractStores.extensionloaded(::Type{<:SQLStore}) = true

#-------------------------------------------------------------------------------
# Statement helpers
#
# Every statement runs under the store's lock: drivers assume one connection has
# one user at a time, and results are lazy cursors, so rows must be read into
# plain Julia values before the lock is released.
#-------------------------------------------------------------------------------

# Parameters always go through a prepared statement. `DBInterface.execute(conn,
# sql, params)` is optional for a driver to support — MySQL.jl rejects it outright
# — whereas prepare/execute is the interface's guaranteed path, and caching the
# statements per store makes it cheaper than the alternative besides.
#
# Cached by SQL text rather than by call site: the table name is interpolated in,
# so one call site serves many tables and `DBInterface.@prepare` would hand every
# store the first one's statement.
prepared(store::SQLStore, sql::AbstractString) =
    get!(() -> DBInterface.prepare(store.conn, String(sql)), store.stmts, String(sql))

rawexec(store::SQLStore, sql, params=()) =
    (isempty(params) ? DBInterface.execute(store.conn, sql) :
                       DBInterface.execute(prepared(store, sql), params); nothing)

rawquery(store::SQLStore, sql, params=()) =
    isempty(params) ? DBInterface.execute(store.conn, sql) :
                      DBInterface.execute(prepared(store, sql), params)

exec!(store::SQLStore, sql, params=()) = @lock store.lock rawexec(store, sql, params)

# Always drain the cursor, and extract into plain Julia values while doing so.
#
# Results are lazy: a row read after the cursor moves on is undefined, and an
# abandoned result set leaves the connection wedged — MySQL answers the next
# command with "Commands out of sync". Since every `fetchone` query here is a
# primary-key lookup or a COUNT, draining costs nothing.
rawfetch(f, store::SQLStore, sql, params=()) = [f(row) for row in rawquery(store, sql, params)]

function fetchone(f, store::SQLStore, sql, params=())
    rows = @lock store.lock rawfetch(f, store, sql, params)
    return isempty(rows) ? nothing : rows[1]
end

fetchall(f, store::SQLStore, sql, params=()) = @lock store.lock rawfetch(f, store, sql, params)

function rawtoken(store::SQLStore, key::String)
    tokens = rawfetch(row -> Int64(row.token), store,
        "SELECT token FROM $(store.table) WHERE store_key = $(placeholder(store.dialect, 1))",
        (key,))
    return isempty(tokens) ? nothing : tokens[1]
end

#-------------------------------------------------------------------------------
# Required interface
#-------------------------------------------------------------------------------

function AbstractStores.createtable!(store::SQLStore)
    exec!(store, """
        CREATE TABLE IF NOT EXISTS $(store.table) (
            store_key $(store.dialect.keytype) NOT NULL PRIMARY KEY,
            store_value $(store.dialect.valuetype) NOT NULL,
            expires_at BIGINT,
            token BIGINT NOT NULL
        )""")
    return store
end

function Base.get(store::SQLStore, key::AbstractString, default)
    d = store.dialect
    text = fetchone(row -> String(row.store_value), store,
        "SELECT store_value FROM $(store.table) WHERE store_key = $(placeholder(d, 1)) " *
        "AND (expires_at IS NULL OR expires_at > $(placeholder(d, 2)))",
        (String(key), nowms()))
    return text === nothing ? default : decodevalue(store, text)
end

function Base.put!(store::SQLStore, key::AbstractString, value; ttl=nothing)
    d = store.dialect
    upsert = d.name === :MySQL ?
        "ON DUPLICATE KEY UPDATE store_value = VALUES(store_value), " *
            "expires_at = VALUES(expires_at), token = VALUES(token)" :
        "ON CONFLICT (store_key) DO UPDATE SET store_value = EXCLUDED.store_value, " *
            "expires_at = EXCLUDED.expires_at, token = EXCLUDED.token"
    exec!(store,
        "INSERT INTO $(store.table) (store_key, store_value, expires_at, token) " *
        "VALUES ($(placeholders(d, 4))) $upsert",
        (String(key), encodevalue(store, value), unixms(expiryof(ttl)), rand(Int64)))
    return store
end

function Base.delete!(store::SQLStore, key::AbstractString)
    exec!(store, "DELETE FROM $(store.table) WHERE store_key = $(placeholder(store.dialect, 1))",
          (String(key),))
    return store
end

function Base.haskey(store::SQLStore, key::AbstractString)
    d = store.dialect
    return fetchone(_ -> true, store,
        "SELECT 1 AS present FROM $(store.table) WHERE store_key = $(placeholder(d, 1)) " *
        "AND (expires_at IS NULL OR expires_at > $(placeholder(d, 2)))",
        (String(key), nowms())) === true
end

# The LIKE is an index-friendly prefilter; the `startswith` afterward is the
# contract. SQLite's LIKE is case-insensitive for ASCII no matter how the column
# is declared, so without the client-side filter `keys(prefix="NS/")` would list
# (and `empty!` would delete!) "ns/..." keys.
function Base.keys(store::SQLStore; prefix::AbstractString="")
    d = store.dialect
    ks = fetchall(row -> String(row.store_key), store,
        "SELECT store_key FROM $(store.table) WHERE store_key LIKE $(placeholder(d, 1)) ESCAPE '!' " *
        "AND (expires_at IS NULL OR expires_at > $(placeholder(d, 2)))",
        (likeprefix(prefix), nowms()))
    return isempty(prefix) ? ks : filter!(k -> startswith(k, prefix), ks)
end

function Base.empty!(store::SQLStore; prefix::AbstractString="")
    d = store.dialect
    if isempty(prefix)
        exec!(store, "DELETE FROM $(store.table)")
    else
        # One statement, so the delete stays atomic. The LIKE is the
        # index-friendly prefilter; the substr equality is the byte-exact guard
        # SQLite's case-folding LIKE needs. substr counts characters on TEXT
        # columns but bytes on MySQL's VARBINARY, hence the dialect-aware
        # length. No expiry filter: `empty!` reclaims expired rows too.
        n = d.name === :MySQL ? ncodeunits(prefix) : length(prefix)
        exec!(store,
            "DELETE FROM $(store.table) WHERE store_key LIKE $(placeholder(d, 1)) ESCAPE '!' " *
            "AND substr(store_key, 1, $(placeholder(d, 2))) = $(placeholder(d, 3))",
            (likeprefix(prefix), n, String(prefix)))
    end
    return store
end

function AbstractStores.sweep!(store::SQLStore)
    d = store.dialect
    now = nowms()
    where = "WHERE expires_at IS NOT NULL AND expires_at <= $(placeholder(d, 1))"
    n = fetchone(row -> Int(row.n), store,
                 "SELECT COUNT(*) AS n FROM $(store.table) $where", (now,))
    n = something(n, 0)
    n > 0 && exec!(store, "DELETE FROM $(store.table) $where", (now,))
    return n
end

#-------------------------------------------------------------------------------
# Compare-and-swap `modify!`
#-------------------------------------------------------------------------------

# Read value and CAS token together. An expired row reads as absent but keeps its
# token, so a CAS against it still replaces exactly the row we looked at.
function readrow(store::SQLStore, key::String)
    d = store.dialect
    got = fetchone(store,
        "SELECT store_value, expires_at, token FROM $(store.table) " *
        "WHERE store_key = $(placeholder(d, 1))", (key,)) do row
        exp = row.expires_at
        live = exp === nothing || ismissing(exp) || Int64(exp) > nowms()
        (live ? String(row.store_value) : nothing, Int64(row.token))
    end
    got === nothing && return (nothing, nothing)
    text, token = got
    return (text === nothing ? nothing : decodevalue(store, text), token)
end

# Claim a key that had no row at all, without provoking an error.
#
# The obvious spelling — plain INSERT, catch the uniqueness violation — is wrong
# here for two reasons: it makes the common contended path an exception, and a
# failed statement leaves some drivers' connections unusable (MySQL answers the
# next command with "Commands out of sync"; Postgres poisons an open
# transaction). A conflict-tolerant insert plus the same token check used
# everywhere else says exactly as much, quietly.
function casinsert(store::SQLStore, key::String, text::String,
                   expires::Union{Missing,Int64}, newtoken::Int64)
    d = store.dialect
    sql = d.name === :MySQL ?
        "INSERT IGNORE INTO $(store.table) (store_key, store_value, expires_at, token) " *
            "VALUES ($(placeholders(d, 4)))" :
        "INSERT INTO $(store.table) (store_key, store_value, expires_at, token) " *
            "VALUES ($(placeholders(d, 4))) ON CONFLICT (store_key) DO NOTHING"
    won = Ref(false)
    @lock store.lock DBInterface.transaction(store.conn) do
        rawexec(store, sql, (key, text, expires, newtoken))
        won[] = rawtoken(store, key) == newtoken
        return nothing
    end
    return won[]
end

# Apply a token-conditional write and report, reliably, whether it landed.
#
# The write and the check must share a transaction: without one, a second writer
# committing in between makes our successful write look failed, and the retry
# would apply `f` a second time.
function caswrite(store::SQLStore, key::String, text::Union{Nothing,String},
                  expires::Union{Missing,Int64}, oldtoken::Int64, newtoken::Int64)
    d = store.dialect
    t = store.table
    # Carried out through a Ref rather than the transaction's return value:
    # `DBInterface.transaction` is not consistent about propagating it (MySQL.jl
    # returns the commit's result, discarding the closure's).
    won = Ref(false)
    @lock store.lock DBInterface.transaction(store.conn) do
        if text === nothing
            # Delete: claim the row with an already-expired tombstone, then reap it
            # only once we know we won. A crash in between leaves an expired row,
            # which reads as absent and is reclaimed by `sweep!`.
            rawexec(store, "UPDATE $t SET store_value = '', expires_at = 0, " *
                    "token = $(placeholder(d, 1)) WHERE store_key = $(placeholder(d, 2)) " *
                    "AND token = $(placeholder(d, 3))", (newtoken, key, oldtoken))
            won[] = rawtoken(store, key) == newtoken
            won[] && rawexec(store, "DELETE FROM $t WHERE store_key = $(placeholder(d, 1)) " *
                             "AND token = $(placeholder(d, 2))", (key, newtoken))
        else
            rawexec(store, "UPDATE $t SET store_value = $(placeholder(d, 1)), " *
                    "expires_at = $(placeholder(d, 2)), token = $(placeholder(d, 3)) " *
                    "WHERE store_key = $(placeholder(d, 4)) AND token = $(placeholder(d, 5))",
                    (text, expires, newtoken, key, oldtoken))
            won[] = rawtoken(store, key) == newtoken
        end
        return nothing
    end
    return won[]
end

# The value type a typed view passes through is irrelevant here: the server
# owns the value type and the operation is natively atomic.
AbstractStores.modify!(::Type, f, store::SQLStore, key::AbstractString; ttl=nothing) =
    AbstractStores.modify!(f, store, key; ttl)

function AbstractStores.modify!(f, store::SQLStore, key::AbstractString; ttl=nothing)
    k = String(key)
    for _ in 1:MAX_CAS_ATTEMPTS
        old, token = readrow(store, k)
        new = f(old)
        new === old && return new       # unchanged: don't write, don't touch the expiry
        newtoken = rand(Int64)
        expires = unixms(expiryof(ttl))
        if token === nothing
            # No row at all: insert if nobody beat us to it, then re-read on loss.
            new === nothing && return nothing
            casinsert(store, k, encodevalue(store, new), expires, newtoken) && return new
        else
            text = new === nothing ? nothing : encodevalue(store, new)
            caswrite(store, k, text, expires, token, newtoken) && return new
        end
    end
    throw(ConcurrencyError(k, MAX_CAS_ATTEMPTS))
end

end # module
