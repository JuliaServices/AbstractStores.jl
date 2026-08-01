# SQLStore: type, dialects, and pure helpers. The methods that actually talk to a
# database live in `ext/AbstractStoresDBInterfaceExt.jl`.

"""
    AbstractStores.SQLDialect

The handful of ways SQL databases disagree about writing the same statement:
parameter placeholders (`?` vs `\$1`), the types of the key and value columns,
and upsert syntax.

Values: [`AbstractStores.SQLITE`](@ref), [`AbstractStores.MYSQL`](@ref),
[`AbstractStores.POSTGRES`](@ref).  [`SQLStore`](@ref) detects the right one from
the connection type; pass `dialect` explicitly for a driver it does not know.
"""
struct SQLDialect
    name::Symbol
    numbered::Bool      # $1, $2, ... instead of ?
    keytype::String
    valuetype::String
end

"Dialect for SQLite.jl connections. See [`SQLDialect`](@ref)."
const SQLITE = SQLDialect(:SQLite, false, "TEXT", "TEXT")
# The explicit binary collation is load-bearing: MySQL's default utf8mb4
# collation is case- and accent-insensitive, under which "Key" and "key" would be
# the *same primary key* and silently upsert over each other. MEDIUMTEXT rather
# than TEXT because TEXT caps values at 64KiB (~48KiB of payload after base64).
"Dialect for MySQL.jl / MariaDB connections. See [`SQLDialect`](@ref)."
const MYSQL = SQLDialect(:MySQL, false,
                         "VARCHAR(512) CHARACTER SET utf8mb4 COLLATE utf8mb4_bin",
                         "MEDIUMTEXT")
"Dialect for Postgres.jl / LibPQ.jl connections. See [`SQLDialect`](@ref)."
const POSTGRES = SQLDialect(:Postgres, true, "TEXT", "TEXT")

placeholder(d::SQLDialect, i::Integer) = d.numbered ? string('$', i) : "?"
placeholders(d::SQLDialect, n::Integer) = join((placeholder(d, i) for i in 1:n), ", ")

"""
    AbstractStores.detectdialect(conn) -> SQLDialect

Infer a [`SQLDialect`](@ref) from the module that owns `conn`'s type.  Throws for
unrecognized drivers, which is the cue to pass `dialect` explicitly.
"""
function detectdialect(conn)
    mod = nameof(parentmodule(typeof(conn)))
    mod === :SQLite && return SQLITE
    mod === :MySQL && return MYSQL
    (mod === :Postgres || mod === :LibPQ) && return POSTGRES
    throw(ArgumentError(
        "could not infer a SQL dialect from connection type $(typeof(conn)); " *
        "pass one explicitly, e.g. `SQLStore{T}(conn; dialect=AbstractStores.POSTGRES)`"))
end

"""
    SQLStore{T}(conn; table="abstract_store", codec=SerializedCodec(),
                dialect=<detected>, create=true)

A store backed by a single SQL table, over any
[DBInterface.jl](https://github.com/JuliaDatabases/DBInterface.jl) connection —
SQLite, MySQL, and Postgres are detected automatically.

This is a layer boundary worth noticing: `DBInterface` abstracts over *databases*,
`AbstractStores` abstracts over *persistence*, and this type is the adapter
between them.  One implementation covers every SQL backend.

# Schema

    CREATE TABLE <table> (
        store_key   TEXT PRIMARY KEY,   -- VARCHAR(512) ... COLLATE utf8mb4_bin on MySQL
        store_value TEXT NOT NULL,      -- base64 of the codec's bytes; MEDIUMTEXT on MySQL
        expires_at  BIGINT,             -- unix milliseconds; NULL means never
        token       BIGINT NOT NULL     -- compare-and-swap token
    )

Values are base64 text rather than `BLOB`/`BYTEA`, so the only parameter types
crossing the driver boundary are `String` and `Int64`.  That costs 33% in size and
buys identical behavior on every driver with no binary-binding quirks.  Expiry is
unix milliseconds compared against a bound parameter, so no server-side time or
timezone functions are involved.

Keys compare byte-exactly on every dialect: MySQL's key column carries an
explicit binary collation (its default collation would fold case and accents,
making `"Key"` and `"key"` the same row), and prefix listing filters
client-side where a dialect's `LIKE` is not case-sensitive (SQLite).

`table` is interpolated into SQL and is therefore restricted to alphanumerics and
underscores.  Everything else — keys, values, expiry — is bound as a parameter.

- [`supportsttl`](@ref): `true`, filtered server-side; [`sweep!`](@ref) reclaims rows
- [`supportslisting`](@ref): `true`, `keys(store; prefix=...)` becomes a `LIKE`
- [`isatomic`](@ref): `true`, see below

# Atomicity

`modify!`, `pop!`, and `get!` use optimistic concurrency: each row carries a random
`token`, and every write is conditional on the token the reader saw
(`UPDATE ... WHERE store_key = ? AND token = ?`).  A losing writer retries.  No
`SELECT ... FOR UPDATE` and no dialect-specific row-locking semantics are
involved, so this is genuinely atomic across processes on all three databases.

The write and the check of whether it landed run inside a short
`DBInterface.transaction`, which is what makes the check trustworthy — without
it, a second writer committing in between would make a *successful* write look
failed, and the retry would apply `f` twice.  Your callback runs outside that
transaction, so a slow `f` never holds a database lock.

A `modify!` that deletes writes an expired tombstone first and reaps it only once
the token check confirms the win, so exactly one caller can `pop!` a given key.
A crash in between leaves an expired row, which reads as absent and is reclaimed
by [`sweep!`](@ref).

!!! warning "`f` may run more than once"
    That is inherent to compare-and-swap: under contention your callback is
    retried against the newer value, so keep it pure.  After
    [`MAX_CAS_ATTEMPTS`](@ref) failed attempts a [`ConcurrencyError`](@ref) is
    thrown rather than spinning forever.

!!! note "Connection sharing and nested transactions"
    Every statement is issued under a store-local `ReentrantLock`, because
    database drivers generally assume one connection has one user at a time.
    Sharing *a* `SQLStore` across tasks is therefore safe.  The lock is per
    store, not per connection: two `SQLStore`s (or a store and your own code)
    sharing one connection are **not** coordinated — give each store its own
    connection, or serialize access yourself.  Calling `modify!` from inside a
    transaction you opened yourself is likewise unsupported — `modify!` opens
    its own.  Prepared statements are cached for the life of the store and are
    released when the connection is closed.

!!! note "Requires DBInterface.jl"
    The methods live in a package extension.  `using DBInterface` alongside your
    driver (SQLite, MySQL, Postgres) to enable them.

# Examples
```julia
using AbstractStores, DBInterface, SQLite

db = SQLite.DB("state.sqlite")
jobs = SQLStore{Job}(db; table="tempus_jobs", codec=JSONCodec())

jobs["nightly-report"] = job
collect(keys(jobs))
pop!(jobs, "nightly-report", nothing)     # atomic across processes
```
"""
struct SQLStore{T,C<:AbstractCodec,Conn} <: AbstractStore{T}
    conn::Conn
    table::String
    codec::C
    dialect::SQLDialect
    lock::ReentrantLock
    # Prepared statements, keyed by SQL text. Parameters are always bound through
    # a prepared statement: it is the portable path (MySQL.jl supports no other),
    # and it is what lets every key and value cross as a bound parameter rather
    # than string interpolation.
    stmts::Dict{String,Any}
end

"""
    AbstractStores.createtable!(store::SQLStore) -> store

Issue `CREATE TABLE IF NOT EXISTS` for `store`'s table.  Called by the constructor
unless `create=false`, which is the right choice when a migration tool owns the
schema.
"""
function createtable! end

function SQLStore{T}(conn; table::AbstractString="abstract_store",
                     codec::AbstractCodec=SerializedCodec(),
                     dialect::SQLDialect=detectdialect(conn),
                     create::Bool=true) where {T}
    extensionloaded(SQLStore) || throw(ArgumentError(
        "SQLStore requires DBInterface.jl: `using DBInterface` (plus your driver — " *
        "SQLite, MySQL, or Postgres) to load the AbstractStoresDBInterfaceExt extension."))
    all(c -> isletter(c) || isdigit(c) || c == '_', table) || throw(ArgumentError(
        "table name is interpolated into SQL and must be alphanumeric or underscore, " *
        "got $(repr(String(table)))"))
    store = SQLStore{T,typeof(codec),typeof(conn)}(conn, String(table), codec, dialect,
                                                   ReentrantLock(), Dict{String,Any}())
    create && createtable!(store)
    return store
end

supportsttl(::SQLStore) = true
supportslisting(::SQLStore) = true
isatomic(::SQLStore) = true

Base.lock(f, store::SQLStore) = lock(f, store.lock)

unixms(t::DateTime) = round(Int64, Dates.datetime2unix(t) * 1000)
# `missing`, not `nothing`, is the portable spelling of SQL NULL as a bound
# parameter: SQLite.jl accepts either, Postgres.jl documents `missing`, and
# MySQL.jl has no `bind!` method for `Nothing` at all.
unixms(::Nothing) = missing
nowms() = unixms(Dates.now(UTC))

"""
    AbstractStores.likeprefix(prefix) -> String

Turn a key prefix into a SQL `LIKE` pattern, escaping `%`, `_`, and the escape
character itself.  `!` is used as the escape character because, unlike `\\`, it
needs no dialect-specific quoting inside the `ESCAPE` clause.
"""
function likeprefix(prefix::AbstractString)
    io = IOBuffer()
    for c in prefix
        (c == '!' || c == '%' || c == '_') && write(io, '!')
        write(io, c)
    end
    write(io, '%')
    return String(take!(io))
end

encodevalue(store::SQLStore{T}, value) where {T} =
    Base64.base64encode(encode(store.codec, convert(T, value)))
decodevalue(store::SQLStore{T}, text) where {T} =
    decode(store.codec, T, Base64.base64decode(String(text)))

Base.show(io::IO, store::SQLStore{T}) where {T} = print(io,
    "SQLStore{", T, "}(", store.dialect.name, ", table=", repr(store.table), ")")
