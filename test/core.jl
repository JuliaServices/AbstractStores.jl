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
    @test @inferred(lock(() -> 42, store)) == 42

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
    @test @inferred(lock(() -> 42, FileStore{Int}(mktempdir()))) == 42

    @testset "key encoding" begin
        # round-trip
        for key in ["plain", "a/b", "../../etc/passwd", ".", "..", ".hidden",
                    "ünïcødé", "%2F", "with space", "\0nul", "\r\n", "tab\t",
                    "CASE", "MixedCase", "con", "COM1.txt", "console", "nul.a.b",
                    "trail.", "trail ", "a...", "..."]
            @test decodekey(encodekey(key)) == key
        end
        # Win32 strips trailing dots (and spaces) from a path component, so a
        # canonical name must never end in either
        for key in ["a.", "..", "...", "con.", "dot.dot.", "sp. "]
            name = encodekey(key)
            @test !endswith(name, '.') && !endswith(name, ' ')
        end
        @test encodekey("a.") == "a%2E"
        @test encodekey("..") == "%2E%2E"
        @test decodekey("%2E.") === nothing    # the old spelling of ".." is no longer canonical
        # nothing escapes the directory, and no name is a dotfile
        for key in ["../x", "..", ".", "/abs", "a/../../b", ".hidden"]
            name = encodekey(key)
            @test !occursin('/', name)
            @test !startswith(name, '.')
        end
        # distinct keys never collide — even under a case-folding, unicode-
        # normalizing filesystem (APFS, NTFS), so encoded names may differ only
        # in [a-z0-9._-] and uppercase hex escapes
        keyset = ["a/b", "a%2Fb", "a", "b", "A", "%", "%%", "case", "CASE",
                  "cafe", "café"]
        names = encodekey.(keyset)
        @test length(unique(names)) == length(keyset)
        @test length(unique(lowercase.(names))) == length(keyset)
        # Windows-reserved device names never appear verbatim
        for key in ["con", "CON", "nul.txt", "com1", "lpt9.log"]
            stem = first(split(encodekey(key), '.'; limit=2))
            @test !(lowercase(stem) in AbstractStores.WINDOWS_RESERVED)
        end
        # non-encodings are rejected rather than silently mangled
        @test decodekey("%") === nothing
        @test decodekey("%ZZ") === nothing
        @test decodekey("%4") === nothing
        # ...and so are non-canonical spellings, so no two listable names can
        # decode to the same key
        @test decodekey("%61") === nothing          # 'a' is safe, never escaped
        @test decodekey("%2f") === nothing          # lowercase hex is never emitted
        @test decodekey("a%2Eb") === nothing        # '.' never escaped mid-name
        @test decodekey("a%2E") == "a."             # ...but always escaped trailing
        @test decodekey("%2E") == "."               # ...and leading
        @test decodekey("a b") === nothing          # raw unsafe byte: not our file
        @test decodekey("CASE") === nothing         # raw uppercase: not our file
        @test decodekey("con") === nothing          # reserved stem: we escape it
        @test decodekey(encodekey("CASE")) == "CASE"
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
        @test store["secret"] == "hunter2"

        # Windows has no POSIX mode bits — `chmod` there only toggles read-only,
        # so the mode assertions (and FileStore's confidentiality claim) are
        # unix-only. See the FileStore docstring.
        if Sys.isunix()
            @test (filemode(joinpath(dir, "secret")) & 0o777) == 0o600
            @test (filemode(dir) & 0o777) == 0o700
        end

        open = FileStore{String}(mktempdir(); permissions=0o644, dirpermissions=0o755)
        open["public"] = "ok"
        @test open["public"] == "ok"
        Sys.isunix() && @test (filemode(joinpath(open.dir, "public")) & 0o777) == 0o644

        # permissions=nothing skips chmod entirely
        none = FileStore{String}(mktempdir(); permissions=nothing, dirpermissions=nothing)
        none["k"] = "v"
        @test none["k"] == "v"
    end

    @testset "long keys" begin
        store = FileStore{String}(mktempdir())
        @test_throws ArgumentError store["x"^300] = "too long"
        store["x"^200] = "fits"           # 200 chars encode to 200 bytes
        @test store["x"^200] == "fits"
        # the budget leaves room for the temp-file adornment, so the boundary
        # is a clean ArgumentError, never an ENAMETOOLONG at write time
        limit = AbstractStores.MAX_FILENAME_BYTES - AbstractStores.TMP_NAME_OVERHEAD
        store["x"^limit] = "exactly"
        @test store["x"^limit] == "exactly"
        @test_throws ArgumentError store["x"^(limit + 1)] = "one too many"
    end

    @testset "the empty key has no filename" begin
        store = FileStore{String}(mktempdir())
        @test_throws ArgumentError store[""] = "v"
        @test_throws ArgumentError store[""]
    end

    @testset "case-colliding keys stay distinct on any filesystem" begin
        # APFS and NTFS case-fold filenames; the encoding must absorb that
        dir = mktempdir()
        store = FileStore{String}(dir)
        store["token"] = "lower"
        store["TOKEN"] = "upper"
        store["Token"] = "mixed"
        @test store["token"] == "lower"
        @test store["TOKEN"] == "upper"
        @test store["Token"] == "mixed"
        @test length(collect(keys(store))) == 3
        # reserved names are storable as keys
        store["con"] = "device?"
        @test store["con"] == "device?"
        @test "con" in keys(store)
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

    @testset "typed views over a value-erased FileStore" begin
        parent = FileStore{Any}(mktempdir())
        root = PrefixedStore(parent, "root/")
        typed = PrefixedStore{Token}(root, "tokens/")

        # Exercise both files written through the typed view and wider
        # Entry{Any} files left by direct access to the shared parent.
        typed["new"] = TOKENS[1]
        parent["root/tokens/existing"] = TOKENS[2]
        @test typed["new"] == TOKENS[1]
        @test typed["existing"] == TOKENS[2]

        @test get!(typed, "new", TOKENS[3]) == TOKENS[1]
        @test get!(typed, "created", TOKENS[3]) == TOKENS[3]
        @test modify!(_ -> TOKENS[2], typed, "created") == TOKENS[2]
        @test typed["created"] == TOKENS[2]

        put!(typed, "expired", TOKENS[1]; ttl=Millisecond(20))
        sleep(0.1)
        @test Set(keys(typed)) == Set(["new", "existing", "created"])
    end
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

@testset "checkstore" begin
    mem = MemoryStore{String}()
    @test checkstore(mem) === mem
    @test checkstore(mem; ttl=true, atomic=true, listing=true) === mem

    file = FileStore{String}(mktempdir())               # ttl yes, atomic no
    @test checkstore(file; ttl=true) === file
    @test_throws ArgumentError checkstore(file; atomic=true)

    raw = FileStore{String}(mktempdir(); codec=RawCodec())   # no ttl either
    @test_throws ArgumentError checkstore(raw; ttl=true)

    # the error says which trait is missing
    err = try checkstore(file; atomic=true); nothing catch e; e end
    @test err isa ArgumentError && occursin("isatomic", err.msg)
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
    @test @inferred(pop!(store, "p", 0)) == 9
    @test pop!(store, "p", :gone) === :gone

    # get! converts new values to the store element type and returns that type.
    @test @inferred(get!(store, "converted", UInt8(3))) === 3
    @test @inferred(get!(() -> UInt8(4), store, "generated")) === 4
    @test_throws InexactError get!(store, "invalid", 1.5)
end

@testset "SQL helpers" begin
    @test placeholder(SQLITE, 1) == "?"
    @test placeholder(POSTGRES, 3) == "\$3"
    @test placeholders(SQLITE, 3) == "?, ?, ?"
    @test placeholders(POSTGRES, 3) == "\$1, \$2, \$3"
    # VARBINARY: every utf8mb4 collation folds something — case and accents by
    # default, trailing spaces even under utf8mb4_bin (PAD SPACE)
    @test MYSQL.keytype == "VARBINARY(512)"
    @test MYSQL.valuetype == "MEDIUMTEXT"

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
