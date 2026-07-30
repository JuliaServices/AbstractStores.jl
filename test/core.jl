using AbstractStores: supportsttl, supportslisting, isatomic, encodekey, decodekey,
    Entry, expiryof, ttlseconds, likeprefix, globescape, detectdialect,
    SQLITE, MYSQL, POSTGRES, placeholder, placeholders

@testset "MemoryStore" begin
    AbstractStores.runstoretests(() -> MemoryStore{String}(), ["a", "b", "c"])
    AbstractStores.runstoretests(() -> MemoryStore{Int}(), [1, 2, 3])
    AbstractStores.runstoretests(() -> MemoryStore{Token}(), TOKENS)
    AbstractStores.runstoretests(() -> MemoryStore(), Any["a", 2, TOKENS[1]];
                                 name="MemoryStore{Any}")

    store = MemoryStore{Int}()
    @test eltype(store) === Int
    @test valtype(store) === Int
    @test keytype(store) === String
    @test sprint(show, store) == "MemoryStore{Int64}(0 keys)"

    # values are converted to the store's eltype
    store["n"] = 0x05
    @test store["n"] === 5

    # sweep! physically reclaims, and reports what it reclaimed
    swept = MemoryStore{Int}()
    put!(swept, "a", 1; ttl=Millisecond(50))
    put!(swept, "b", 2)
    sleep(0.2)
    @test length(swept.data) == 2      # still present internally...
    @test sweep!(swept) == 1           # ...until swept
    @test length(swept.data) == 1
    @test sweep!(swept) == 0
end

@testset "FileStore" begin
    AbstractStores.runstoretests(["a", "b", "c"]) do
        FileStore{String}(mktempdir())
    end
    AbstractStores.runstoretests(TOKENS; name="FileStore{Token}") do
        FileStore{Token}(mktempdir())
    end

    @testset "key encoding" begin
        # round-trip
        for key in ["plain", "a/b", "../../etc/passwd", "", ".", "..", ".hidden",
                    "ünïcødé", "%2F", "with space", "\0nul", "\r\n", "tab\t"]
            @test decodekey(encodekey(key)) == key
        end
        # nothing escapes the directory, and no name is a dotfile
        for key in ["../x", "..", ".", "/abs", "a/../../b", ".hidden"]
            name = encodekey(key)
            @test !occursin('/', name)
            @test !startswith(name, '.')
        end
        # distinct keys never collide
        keyset = ["a/b", "a%2Fb", "a", "b", "A", "%", "%%"]
        @test length(unique(encodekey.(keyset))) == length(keyset)
        # non-encodings are rejected rather than silently mangled
        @test decodekey("%") === nothing
        @test decodekey("%ZZ") === nothing
        @test decodekey("%4") === nothing
    end

    @testset "on-disk layout" begin
        dir = mktempdir()
        store = FileStore{String}(dir)
        store["a/b"] = "v"
        @test readdir(dir) == ["a%2Fb"]
        @test read(joinpath(dir, "a%2Fb")) isa Vector{UInt8}

        # a foreign dotfile is ignored, not an error
        write(joinpath(dir, ".DS_Store"), "junk")
        @test collect(keys(store)) == ["a/b"]

        # writes are atomic: no temp file survives
        @test !any(startswith('.'), filter(!=(".DS_Store"), readdir(dir)))
    end

    @testset "permissions" begin
        dir = mktempdir()
        store = FileStore{String}(dir)
        store["secret"] = "hunter2"
        @test (filemode(joinpath(dir, "secret")) & 0o777) == 0o600
        @test (filemode(dir) & 0o777) == 0o700

        open = FileStore{String}(mktempdir(); permissions=0o644, dirpermissions=0o755)
        open["public"] = "ok"
        @test (filemode(joinpath(open.dir, "public")) & 0o777) == 0o644
    end

    @testset "long keys" begin
        store = FileStore{String}(mktempdir())
        @test_throws ArgumentError store["x"^300] = "too long"
        store["x"^200] = "fits"           # 200 chars encode to 200 bytes
        @test store["x"^200] == "fits"
    end

    @testset "persistence across store instances" begin
        dir = mktempdir()
        FileStore{Token}(dir)["tok"] = TOKENS[1]
        @test FileStore{Token}(dir)["tok"] == TOKENS[1]
    end

    @testset "RawCodec has no expiry" begin
        store = FileStore{String}(mktempdir(); codec=RawCodec())
        @test !supportsttl(store)
        @test_throws ArgumentError put!(store, "k", "v"; ttl=Second(30))
        store["k"] = "verbatim"
        @test read(joinpath(store.dir, "k"), String) == "verbatim"   # bytes are the value
        @test store["k"] == "verbatim"
        @test sweep!(store) == 0
    end
end

@testset "PrefixedStore" begin
    AbstractStores.runstoretests(["a", "b", "c"]) do
        PrefixedStore(MemoryStore{String}(), "p/")
    end
    AbstractStores.runstoretests(["a", "b", "c"]; name="PrefixedStore(FileStore)") do
        PrefixedStore(FileStore{String}(mktempdir()), "p/")
    end

    backend = MemoryStore{String}()
    tokens = PrefixedStore(backend, "oauth/refresh/")
    codes = PrefixedStore(backend, "oauth/code/")

    tokens["alice"] = "rt_abc"
    codes["xyz"] = "grant"

    @test collect(keys(tokens)) == ["alice"]
    @test collect(keys(codes)) == ["xyz"]
    @test Set(keys(backend)) == Set(["oauth/refresh/alice", "oauth/code/xyz"])
    @test backend["oauth/refresh/alice"] == "rt_abc"

    # empty! is scoped to the prefix
    empty!(codes)
    @test isempty(codes)
    @test collect(keys(tokens)) == ["alice"]

    # traits and native atomicity are inherited, not lost
    @test isatomic(tokens) == isatomic(backend)
    @test supportsttl(tokens) == supportsttl(backend)
    @test pop!(tokens, "alice", nothing) == "rt_abc"
    @test isempty(backend)

    # empty prefix is a no-op view
    plain = PrefixedStore(backend, "")
    plain["k"] = "v"
    @test backend["k"] == "v"
    @test collect(keys(plain)) == ["k"]

    # nesting composes
    nested = PrefixedStore(PrefixedStore(backend, "a/"), "b/")
    nested["c"] = "deep"
    @test backend["a/b/c"] == "deep"
    @test collect(keys(nested)) == ["c"]
end

@testset "interface defaults" begin
    # a store implementing only the required methods still gets everything derived
    struct MinimalStore <: AbstractStore{String}
        d::Dict{String,String}
    end
    Base.get(s::MinimalStore, k::AbstractString, default) = get(s.d, String(k), default)
    Base.put!(s::MinimalStore, k::AbstractString, v; ttl=nothing) =
        (AbstractStores.checkttl(s, ttl); s.d[String(k)] = v; s)
    Base.delete!(s::MinimalStore, k::AbstractString) = (delete!(s.d, String(k)); s)
    Base.keys(s::MinimalStore; prefix::AbstractString="") =
        [k for k in keys(s.d) if startswith(k, prefix)]

    AbstractStores.runstoretests(() -> MinimalStore(Dict{String,String}()),
                                 ["a", "b", "c"]; name="MinimalStore")

    # ...and the traits it did not override are the conservative defaults
    s = MinimalStore(Dict{String,String}())
    @test !supportsttl(s)
    @test !isatomic(s)
    @test supportslisting(s)
    @test sweep!(s) == 0

    # a store implementing nothing reports which method is missing
    struct EmptyStore <: AbstractStore{String} end
    @test_throws ArgumentError get(EmptyStore(), "k", nothing)
    @test_throws ArgumentError put!(EmptyStore(), "k", "v")
    @test_throws ArgumentError delete!(EmptyStore(), "k")
    @test_throws ArgumentError keys(EmptyStore())
end

@testset "ttl normalization" begin
    now = DateTime(2026, 7, 30, 12, 0, 0)
    @test expiryof(nothing) === nothing
    @test expiryof(Second(30), now) == now + Second(30)
    @test expiryof(30, now) == now + Second(30)
    @test expiryof(0.25, now) == now + Millisecond(250)
    @test expiryof(Hour(1), now) == now + Hour(1)
    @test_throws ArgumentError expiryof(0)
    @test_throws ArgumentError expiryof(-1)
    @test_throws ArgumentError expiryof(Second(-5))

    @test ttlseconds(nothing) === nothing
    @test ttlseconds(Second(30)) == 30.0
    @test ttlseconds(Millisecond(1500)) == 1.5
    @test ttlseconds(2.5) == 2.5
    @test_throws ArgumentError ttlseconds(0)
end

@testset "modify! semantics" begin
    store = MemoryStore{Int}()

    # absent -> nothing passed in
    @test modify!(old -> (@test(old === nothing); 1), store, "k") == 1
    # present -> current value passed in
    @test modify!(old -> old + 1, store, "k") == 2
    # returning nothing deletes
    @test modify!(_ -> nothing, store, "k") === nothing
    @test !haskey(store, "k")
    # deleting an already-absent key is a no-op, not an error
    @test modify!(_ -> nothing, store, "k") === nothing

    # ttl applies to the write
    modify!(_ -> 7, store, "t"; ttl=Millisecond(80))
    @test store["t"] == 7
    sleep(0.25)
    @test get(store, "t", nothing) === nothing

    # pop! is modify! with a discard
    store["p"] = 9
    @test pop!(store, "p", nothing) == 9
    @test pop!(store, "p", :gone) === :gone
end

@testset "SQL helpers" begin
    @test placeholder(SQLITE, 1) == "?"
    @test placeholder(POSTGRES, 3) == "\$3"
    @test placeholders(SQLITE, 3) == "?, ?, ?"
    @test placeholders(POSTGRES, 3) == "\$1, \$2, \$3"
    @test MYSQL.keytype == "VARCHAR(512)"

    @test likeprefix("") == "%"
    @test likeprefix("a/b") == "a/b%"
    @test likeprefix("100%") == "100!%%"
    @test likeprefix("a_b") == "a!_b%"
    @test likeprefix("!") == "!!%"

    @test_throws ArgumentError detectdialect(42)
end

@testset "Redis helpers" begin
    @test globescape("plain") == "plain"
    @test globescape("a*b") == "a\\*b"
    @test globescape("a?b[c]") == "a\\?b\\[c\\]"
    @test globescape("back\\slash") == "back\\\\slash"
end

@testset "extension gating" begin
    # constructing a backend without its extension loaded gives a directed error,
    # not a MethodError. (Only meaningful before the ext is loaded; see backends.jl
    # for the loaded case.)
    @test AbstractStores.extensionloaded(MemoryStore) == false   # never has an ext
end
