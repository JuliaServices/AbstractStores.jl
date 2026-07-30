# The migration examples in `examples/` are executable, so the claim that OAuth.jl
# and Tempus.jl can be expressed on this interface is checked rather than asserted.

using Dates, JSON, DBInterface, SQLite

include(joinpath(@__DIR__, "..", "examples", "oauth.jl"))
include(joinpath(@__DIR__, "..", "examples", "tempus.jl"))

using .OAuthStores, .TempusStores

@testset "examples/oauth.jl" begin
    using .OAuthStores: TokenResponse, AccessTokenRecord, AuthorizationCodeRecord,
        ClientConfig, load_refresh_token, save_refresh_token!, clear_refresh_token!,
        store_access_token!, lookup_access_token, revoke_access_token!,
        store_authorization_code!, consume_authorization_code!, check_single_use,
        server_stores

    cfg = ClientConfig("https://issuer.example", "client-abc")
    other = ClientConfig("https://issuer.example", "client-xyz")
    token = TokenResponse("at_1", "rt_1", 3600)

    @testset "refresh tokens on $(nameof(typeof(backend)))" for backend in (
            MemoryStore{TokenResponse}(),
            FileStore{TokenResponse}(mktempdir(); codec=JSONCodec()),
            SQLStore{TokenResponse}(SQLite.DB(); table="refresh", codec=JSONCodec()))
        @test load_refresh_token(backend, cfg) === nothing
        save_refresh_token!(backend, cfg, token)
        @test load_refresh_token(backend, cfg).access_token == "at_1"

        # one store now holds many accounts — the old one-file-per-account
        # FileBasedRefreshTokenStore could not
        save_refresh_token!(backend, other, TokenResponse("at_2", "rt_2", 60))
        @test load_refresh_token(backend, other).access_token == "at_2"
        @test load_refresh_token(backend, cfg).access_token == "at_1"

        clear_refresh_token!(backend, cfg)
        @test load_refresh_token(backend, cfg) === nothing
        @test load_refresh_token(backend, other) !== nothing
    end

    @testset "refresh tokens survive a restart" begin
        dir = mktempdir()
        save_refresh_token!(FileStore{TokenResponse}(dir; codec=JSONCodec()), cfg, token)
        reloaded = load_refresh_token(FileStore{TokenResponse}(dir; codec=JSONCodec()), cfg)
        @test reloaded.access_token == "at_1"
        @test reloaded.refresh_token == "rt_1"
        # and the file is 0o600, as OAuth.jl's hand-written store took care to be
        # (unix only — Windows has no POSIX mode bits)
        Sys.isunix() && @test (filemode(joinpath(dir, readdir(dir)[1])) & 0o777) == 0o600
    end

    @testset "access tokens expire without hand-written checks" begin
        store = MemoryStore{AccessTokenRecord}()
        now = Dates.now(UTC)
        live = AccessTokenRecord("tok_live", ["read"], now, now + Second(3600),
                                 "client-abc", "user-1", false)
        brief = AccessTokenRecord("tok_brief", ["read"], now, now + Millisecond(150),
                                  "client-abc", "user-1", false)

        store_access_token!(store, live; now)
        store_access_token!(store, brief; now)
        @test lookup_access_token(store, "tok_live").subject == "user-1"
        @test lookup_access_token(store, "tok_brief") !== nothing

        sleep(0.4)
        @test lookup_access_token(store, "tok_brief") === nothing   # store expired it
        @test lookup_access_token(store, "tok_live") !== nothing

        revoke_access_token!(store, "tok_live")
        @test lookup_access_token(store, "tok_live") === nothing

        expired = AccessTokenRecord("dead", String[], now, now - Second(1),
                                    nothing, nothing, false)
        @test_throws ArgumentError store_access_token!(store, expired; now)
    end

    @testset "authorization codes are single-use" begin
        db = SQLite.DB()
        @testset "on $label" for (label, store) in (
                "MemoryStore" => MemoryStore{AuthorizationCodeRecord}(),
                "SQLStore" => SQLStore{AuthorizationCodeRecord}(db; table="codes", codec=JSONCodec()))
            now = Dates.now(UTC)
            record = AuthorizationCodeRecord("code-1", "client-abc", "https://app/cb",
                                             ["openid"], "user-1", "challenge", now,
                                             now + Second(60))
            store_authorization_code!(store, record; ttl=Second(60))
            @test consume_authorization_code!(store, "code-1").subject == "user-1"
            @test consume_authorization_code!(store, "code-1") === nothing   # replay rejected

            # concurrent redemption: exactly one caller may win
            store_authorization_code!(store, record; ttl=Second(60))
            wins = Threads.Atomic{Int}(0)
            @sync for _ in 1:16
                Threads.@spawn begin
                    consume_authorization_code!(store, "code-1") === nothing ||
                        Threads.atomic_add!(wins, 1)
                end
            end
            @test wins[] == 1

            # codes expire on their own
            store_authorization_code!(store, record; ttl=Millisecond(150))
            sleep(0.4)
            @test consume_authorization_code!(store, "code-1") === nothing
        end
    end

    @testset "a store that cannot guarantee single use is rejected" begin
        # FileStore is not atomic across processes, so it must not silently be
        # accepted as an authorization-code store
        @test !AbstractStores.isatomic(FileStore{AuthorizationCodeRecord}(mktempdir()))
        @test_throws ArgumentError check_single_use(
            FileStore{AuthorizationCodeRecord}(mktempdir()))
        @test check_single_use(MemoryStore{AuthorizationCodeRecord}()) isa AbstractStore
    end

    @testset "all three stores share one backend" begin
        stores = server_stores(MemoryStore{Any}())
        save_refresh_token!(stores.refresh, cfg, token)
        now = Dates.now(UTC)
        store_access_token!(stores.access,
            AccessTokenRecord("at", String[], now, now + Second(60), nothing, nothing, false); now)
        store_authorization_code!(stores.codes,
            AuthorizationCodeRecord("cd", "c", "u", String[], nothing, nothing, now, now + Second(60)))

        # namespaced apart: emptying one leaves the others alone
        @test collect(keys(stores.refresh)) == [OAuthStores.refresh_key(cfg)]
        empty!(stores.codes)
        @test isempty(stores.codes)
        @test !isempty(stores.refresh)
        @test !isempty(stores.access)
    end
end

@testset "examples/tempus.jl" begin
    using .TempusStores: Job, JobExecution, JobOptions, Scheduler, getJobs, addJob!,
        purgeJob!, disableJob!, storeJobExecution!, getNMostRecentJobExecutions, claim!

    nightly = Job("nightly-report", "Main.report", "0 0 * * *")
    hourly = Job("hourly-sync", "Main.sync", "0 * * * *")

    @testset "job store on $label" for (label, backend) in (
            "MemoryStore" => MemoryStore{Any}(),
            "FileStore" => FileStore{Any}(mktempdir()),
            "SQLStore" => SQLStore{Any}(SQLite.DB(); table="tempus"))
        s = Scheduler(backend)

        @test isempty(getJobs(s))
        addJob!(s, nightly)
        addJob!(s, hourly)
        @test Set(j.name for j in getJobs(s)) == Set(["nightly-report", "hourly-sync"])

        # execution history, bounded and most-recent-first
        base = DateTime(2026, 7, 30)
        for i in 1:5
            storeJobExecution!(s, JobExecution("nightly-report", base + Hour(i), :success))
        end
        recent = getNMostRecentJobExecutions(s, "nightly-report", 3)
        @test length(recent) == 3
        @test recent[1].runAt == base + Hour(5)      # newest first
        @test recent[3].runAt == base + Hour(3)
        @test length(getNMostRecentJobExecutions(s, "nightly-report", 99)) == 5
        @test isempty(getNMostRecentJobExecutions(s, "hourly-sync", 3))
        @test isempty(getNMostRecentJobExecutions(s, "nightly-report", 0))

        # disable is a read-modify-write on the stored job
        @test s.jobs["hourly-sync"].disabledAt === nothing
        disableJob!(s, "hourly-sync"; at=base)
        @test s.jobs["hourly-sync"].disabledAt == base
        @test disableJob!(s, "does-not-exist") === nothing

        # purging a job takes its history with it
        purgeJob!(s, "nightly-report")
        @test [j.name for j in getJobs(s)] == ["hourly-sync"]
        @test isempty(getNMostRecentJobExecutions(s, "nightly-report", 3))
    end

    @testset "history is bounded" begin
        s = Scheduler(MemoryStore{Any}(); history_limit=10)
        base = DateTime(2026, 7, 30)
        for i in 1:50
            storeJobExecution!(s, JobExecution("j", base + Minute(i), :success))
        end
        @test length(getNMostRecentJobExecutions(s, "j", 100)) == 10
        @test getNMostRecentJobExecutions(s, "j", 1)[1].runAt == base + Minute(50)
    end

    @testset "history survives a restart" begin
        # Tempus's own FileStore drops execution history on exit; here it persists
        # because history is just another store.
        dir = mktempdir()
        base = DateTime(2026, 7, 30)
        let s = Scheduler(FileStore{Any}(dir))
            addJob!(s, nightly)
            storeJobExecution!(s, JobExecution("nightly-report", base, :success))
        end
        let s = Scheduler(FileStore{Any}(dir))
            @test [j.name for j in getJobs(s)] == ["nightly-report"]
            @test getNMostRecentJobExecutions(s, "nightly-report", 1)[1].runAt == base
        end
    end

    @testset "concurrent executions do not clobber history" begin
        s = Scheduler(MemoryStore{Any}())
        base = DateTime(2026, 7, 30)
        @sync for i in 1:40
            Threads.@spawn storeJobExecution!(s, JobExecution("j", base + Minute(i), :success))
        end
        @test length(getNMostRecentJobExecutions(s, "j", 100)) == 40
    end

    @testset "leases give exactly one winner" begin
        s = Scheduler(MemoryStore{Any}())
        leases = MemoryStore{String}()
        winners = [w for w in ["worker-a", "worker-b", "worker-c"]
                   if claim!(s, "nightly-report", w, leases; lease=Second(30))]
        @test length(winners) == 1
        @test leases["nightly-report"] == winners[1]

        # ...and a non-atomic store is refused rather than quietly double-scheduling
        @test_throws ArgumentError claim!(s, "j", "w", FileStore{String}(mktempdir()))
    end
end
