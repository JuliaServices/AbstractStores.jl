# Backend extensions, exercised against real services.
#
# SQLite needs nothing. Postgres, MySQL, and Redis run in throwaway containers
# via Harbor.jl (see services.jl); object storage runs against a local Minio from
# CloudBase's own CloudTest harness. Everything skips loudly rather than silently
# when its service is unavailable.

using DBInterface, SQLite, JSON
using AbstractStores: supportsttl, supportslisting, isatomic, ConcurrencyError

"""
    available(mod::Symbol) -> Bool

Load a backend driver if it is present, and say so plainly if it is not.

Only the registry-resolvable test dependencies are declared in `[targets]`, so
that `Pkg.test` works for anyone. JuliaServices/Postgres.jl, JuliaServices/Redis.jl,
and CloudBase's HTTP 2.x are not in General yet; `Pkg.develop` them into the test
environment to exercise those backends.
"""
function available(mod::Symbol)
    try
        @eval using $mod
        return true
    catch err
        @warn "$mod unavailable — its backend tests will be skipped" exception = err
        return false
    end
end

const HAS_MYSQL = available(:MySQL)
const HAS_POSTGRES = available(:Postgres)
const HAS_REDIS = available(:Redis)
const HAS_CLOUD = available(:CloudStore) && available(:CloudBase)

include("services.jl")

const DOCKER = docker_available()
DOCKER || @warn "docker unavailable — Postgres, MySQL, and Redis backends will be skipped"

"""
    sql_conformance(conn, label)

Run the full conformance suite plus the SQL-specific behaviors against a live
connection.  Shared by SQLite, Postgres, and MySQL so all three dialects are held
to exactly the same contract.
"""
function sql_conformance(conn, label::AbstractString)
    n = Ref(0)
    newtable() = (n[] += 1; "store_$(n[])")

    AbstractStores.runstoretests(["a", "b", "c"]; name="SQLStore{String}/$label") do
        SQLStore{String}(conn; table=newtable())
    end
    AbstractStores.runstoretests(TOKENS; name="SQLStore{Token}/$label") do
        SQLStore{Token}(conn; table=newtable(), codec=JSONCodec())
    end
    AbstractStores.runstoretests([1, 2, 3]; name="SQLStore{Int}/$label") do
        SQLStore{Int}(conn; table=newtable())
    end

    @testset "SQL behavior on $label" begin
        store = SQLStore{String}(conn; table="behavior")
        empty!(store)
        @test supportsttl(store) && supportslisting(store) && isatomic(store)

        @testset "the table name is the only interpolated identifier" begin
            @test_throws ArgumentError SQLStore{String}(conn; table="bad; DROP TABLE x")
            @test_throws ArgumentError SQLStore{String}(conn; table="has-dash")
        end

        @testset "keys are bound parameters, so quotes and wildcards are inert" begin
            store["it's a key"] = "quoted"
            @test store["it's a key"] == "quoted"
            store["100% of _"] = "wild"
            store["100"] = "hundred"
            @test store["100% of _"] == "wild"
            @test collect(keys(store; prefix="100%")) == ["100% of _"]
            @test Set(keys(store; prefix="100")) == Set(["100", "100% of _"])
        end

        @testset "sweep! reclaims expired rows" begin
            s = SQLStore{String}(conn; table="sweeper")
            empty!(s)
            put!(s, "gone", "x"; ttl=Millisecond(50))
            put!(s, "stays", "y")
            sleep(0.3)
            @test get(s, "gone", nothing) === nothing   # invisible immediately...
            @test sweep!(s) == 1                         # ...reclaimed on demand
            @test sweep!(s) == 0
            @test s["stays"] == "y"
        end

        @testset "compare-and-swap gives up rather than spinning" begin
            s = SQLStore{Int}(conn; table="cas")
            empty!(s)
            put!(s, "k", 0)
            attempts = Ref(0)
            @test_throws ConcurrencyError modify!(s, "k") do old
                attempts[] += 1
                put!(s, "k", old + 100)     # a competing writer that always wins
                old + 1
            end
            @test attempts[] == AbstractStores.MAX_CAS_ATTEMPTS
        end

        @testset "concurrent modify! does not lose updates" begin
            s = SQLStore{Int}(conn; table="counter")
            empty!(s)
            put!(s, "n", 0)
            @sync for _ in 1:40
                Threads.@spawn modify!(x -> x + 1, s, "n")
            end
            @test s["n"] == 40
        end

        @testset "NULL expiry round-trips as no expiry" begin
            s = SQLStore{String}(conn; table="nullexp")
            empty!(s)
            s["forever"] = "v"
            @test s["forever"] == "v"
            @test modify!(old -> old * "!", s, "forever") == "v!"
            @test s["forever"] == "v!"
        end
    end
end

@testset "SQLStore (SQLite)" begin
    db = SQLite.DB()
    sql_conformance(db, "SQLite")

    store = SQLStore{String}(db; table="dialect")
    @test store.dialect === AbstractStores.SQLITE
    @test occursin("SQLStore{String}(SQLite", sprint(show, store))

    @testset "persistence to a file" begin
        path = joinpath(mktempdir(), "state.sqlite")
        let db2 = SQLite.DB(path)
            SQLStore{Token}(db2; table="tokens", codec=JSONCodec())["t"] = TOKENS[1]
            close(db2)
        end
        let db3 = SQLite.DB(path)
            @test SQLStore{Token}(db3; table="tokens", codec=JSONCodec())["t"] == TOKENS[1]
            close(db3)
        end
    end
end

@testset "SQLStore (Postgres)" begin
    if DOCKER && HAS_POSTGRES
        with_postgres() do conn
            sql_conformance(conn, "Postgres")
            store = SQLStore{String}(conn; table="dialect")
            @test store.dialect === AbstractStores.POSTGRES
            # the dialect really is using numbered placeholders
            @test AbstractStores.placeholders(store.dialect, 2) == "\$1, \$2"
        end
    else
        @test_skip "Postgres backend (docker or Postgres.jl unavailable)"
    end
end

@testset "SQLStore (MySQL)" begin
    if DOCKER && HAS_MYSQL
        with_mysql() do conn
            sql_conformance(conn, "MySQL")
            store = SQLStore{String}(conn; table="dialect")
            @test store.dialect === AbstractStores.MYSQL
            @test store.dialect.keytype == "VARCHAR(512)"
        end
    else
        @test_skip "MySQL backend (docker or MySQL.jl unavailable)"
    end
end

#-------------------------------------------------------------------------------

@testset "RedisStore" begin
    if !(DOCKER && HAS_REDIS)
        @test_skip "Redis backend (docker or Redis.jl unavailable)"
    else
        with_redis() do client
            prefix = "abstractstores-test:"
            fresh(::Type{T}, codec=SerializedCodec()) where {T} = begin
                store = PrefixedStore{T}(RedisStore{T}(client; codec), prefix)
                empty!(store)
                store
            end

            AbstractStores.runstoretests(["a", "b", "c"]; name="RedisStore{String}") do
                fresh(String)
            end
            AbstractStores.runstoretests(TOKENS; name="RedisStore{Token}") do
                fresh(Token, JSONCodec())
            end
            AbstractStores.runstoretests([1, 2, 3]; name="RedisStore{Int}") do
                fresh(Int)
            end

            store = fresh(String)
            @test supportsttl(store) && supportslisting(store) && isatomic(store)
            @test sweep!(store) == 0        # Redis expires keys itself

            @testset "TTL is native, not filtered client-side" begin
                put!(store, "px", "v"; ttl=Millisecond(300))
                @test Redis.get(client, prefix * "px") !== nothing
                sleep(0.8)
                @test Redis.get(client, prefix * "px") === nothing   # gone from Redis
            end

            @testset "CAS compares a token, not the value" begin
                # An A->B->A sequence between our read and our write must still be
                # detected as a conflict, which comparing values alone would miss.
                s = fresh(String)
                put!(s, "k", "A")
                seen = Ref(0)
                result = modify!(s, "k") do old
                    seen[] += 1
                    if seen[] == 1
                        put!(s, "k", "B")   # interleaved writers...
                        put!(s, "k", "A")   # ...restoring the same value
                    end
                    return old * "!"
                end
                @test seen[] == 2           # the retry happened
                @test result == "A!"
                @test s["k"] == "A!"
            end

            @testset "concurrent pop! has exactly one winner" begin
                s = fresh(String)
                put!(s, "prize", "gold")
                wins = Threads.Atomic{Int}(0)
                @sync for _ in 1:20
                    Threads.@spawn (pop!(s, "prize", nothing) === nothing ||
                                    Threads.atomic_add!(wins, 1))
                end
                @test wins[] == 1
            end

            empty!(store)
        end
    end
end

#-------------------------------------------------------------------------------

@testset "ObjectStore" begin
    # Object storage uses CloudBase's own Minio harness (minio_jll) rather than
    # Harbor: it is what CloudStore.jl tests against, and it needs no Docker.
    if !HAS_CLOUD
        @test_skip "ObjectStore backend (CloudStore.jl unavailable)"
    else
    CloudBase.CloudTest.Minio.with() do conf
        # CloudTest.Config names the Bucket/Container `store`, and carries the
        # credentials separately — a Bucket is just a name and a URL.
        bucket, creds = conf.store, conf.credentials
        fresh(::Type{T}, prefix, codec=SerializedCodec()) where {T} = begin
            store = ObjectStore{T}(bucket; prefix, codec, credentials=creds)
            empty!(store)
            store
        end

        # Object keys are opaque, so most awkward keys work verbatim. Excluded:
        # a space (CloudBase never escapes it -> 400) and '%' (its signing does not
        # canonicalize the escape -> 403). See `?AbstractStores.checkobjectkey`.
        urlsafe = ["a/b/c", "dot.dot", "under_score", "dash-dash", "~tilde",
                   "ünïcødé", "plus+eq=", "amp&amp", "hash#hash", "colon:sep",
                   "cafe", "café"]
        # The case pair only when the *local* filesystem distinguishes case:
        # Minio stores each object as a directory path, so on APFS/NTFS
        # "case/x" silently lands inside an existing "Case" — a harness
        # artifact, not S3 behavior (real object stores are byte-exact; the
        # Linux CI run keeps the pair covered).
        if (d = mktempdir(); touch(joinpath(d, "a")); !isfile(joinpath(d, "A")))
            append!(urlsafe, ["case", "CASE"])
        else
            @warn "case-insensitive filesystem: skipping the case-pair keys for the Minio-backed ObjectStore tests"
        end

        AbstractStores.runstoretests(["a", "b", "c"]; name="ObjectStore{String}",
                                     trickykeys=urlsafe) do
            fresh(String, "s1/")
        end
        AbstractStores.runstoretests(TOKENS; name="ObjectStore{Token}",
                                     trickykeys=urlsafe) do
            fresh(Token, "s2/", JSONCodec())
        end

        @testset "unstorable keys are rejected up front, not as a raw 400/403" begin
            s = fresh(String, "esc/")
            for bad in ["with space", "with%20space", "p/../escape", "p/./dot"]
                @test_throws ArgumentError s[bad] = "v"
            end
            # ...and the CloudBase limitation behind that, so this testset fails
            # loudly once signing is fixed and the restriction can be lifted.
            @test_broken try
                CloudStore.put(bucket, "esc/with space", Vector{UInt8}("x"); credentials=creds)
                true
            catch
                false
            end
        end

        store = fresh(String, "traits/")
        @test supportsttl(store)
        @test supportslisting(store)
        @test !isatomic(store)      # object storage exposes no CAS we can reach

        @testset "prefix scopes listing and emptying" begin
            a = fresh(String, "tenant-a/")
            b = fresh(String, "tenant-b/")
            a["cfg"] = "A"
            b["cfg"] = "B"
            @test collect(keys(a)) == ["cfg"]
            @test a["cfg"] == "A" && b["cfg"] == "B"
            empty!(a)
            @test isempty(a)
            @test b["cfg"] == "B"
        end

        @testset "expiry rides in the envelope" begin
            s = fresh(String, "exp/")
            put!(s, "brief", "v"; ttl=Millisecond(300))
            put!(s, "forever", "w")
            @test s["brief"] == "v"
            sleep(0.8)
            @test get(s, "brief", nothing) === nothing
            @test collect(keys(s)) == ["forever"]
            @test sweep!(s) == 0     # the expired read already reclaimed it
        end

        @testset "RawCodec stores the value verbatim" begin
            raw = fresh(String, "raw/", RawCodec())
            @test !supportsttl(raw)
            @test_throws ArgumentError put!(raw, "k", "v"; ttl=Second(30))
            raw["k"] = "verbatim"
            @test String(CloudStore.get(bucket, "raw/k"; credentials=creds)) == "verbatim"
            # slash-delimited keys stay browsable rather than being flattened
            raw["nested/deep/key"] = "kept"
            @test String(CloudStore.get(bucket, "raw/nested/deep/key"; credentials=creds)) == "kept"
            @test Set(keys(raw)) == Set(["k", "nested/deep/key"])
            @test raw["k"] == "verbatim"
        end
    end   # Minio.with
    end   # if HAS_CLOUD
end
