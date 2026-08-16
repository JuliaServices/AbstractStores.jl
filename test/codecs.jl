using JSON
using AbstractStores: encode, decode, encodeentry, decodeentry, canexpire, Entry

@testset "codecs" begin
    @testset "SerializedCodec" begin
        c = SerializedCodec()
        @test canexpire(c)
        for v in (["a", "b"], 42, TOKENS[1], Dict("k" => 1), nothing)
            @test decode(c, typeof(v), encode(c, v)) == v
        end
        e = Entry{Token}(TOKENS[2], DateTime(2026, 1, 1))
        back = decodeentry(c, Token, encodeentry(c, e))
        @test back.value == e.value && back.expires == e.expires
    end

    @testset "JSONCodec" begin
        c = JSONCodec()
        @test canexpire(c)
        @test decode(c, Token, encode(c, TOKENS[1])) == TOKENS[1]
        @test decode(c, Vector{String}, encode(c, ["a", "b"])) == ["a", "b"]
        @test decode(c, Int, encode(c, 42)) == 42

        # envelopes round-trip, including a null expiry
        for exp in (nothing, DateTime(2026, 7, 30, 12, 0, 0))
            e = Entry{Token}(TOKENS[1], exp)
            back = decodeentry(c, Token, encodeentry(c, e))
            @test back.value == e.value
            @test back.expires == e.expires
        end

        # and the bytes on disk are readable JSON, which is the whole point
        json = String(encodeentry(c, Entry{Token}(TOKENS[1], nothing)))
        @test occursin("\"access\":\"at_1\"", json)
        @test occursin("\"expires\":null", json)
    end

    @testset "RawCodec" begin
        c = RawCodec()
        @test !canexpire(c)
        @test decode(c, String, encode(c, "hello")) == "hello"
        @test decode(c, Vector{UInt8}, encode(c, UInt8[1, 2, 3])) == UInt8[1, 2, 3]
        @test_throws ArgumentError encode(c, 42)
        @test_throws ArgumentError decode(c, Int, UInt8[1])
        @test_throws ArgumentError encodeentry(c, Entry{String}("x", nothing))
        @test_throws ArgumentError decodeentry(c, String, UInt8[])
    end

    @testset "codec choice is orthogonal to backend" begin
        for codec in (SerializedCodec(), JSONCodec())
            store = FileStore{Token}(mktempdir(); codec)
            store["t"] = TOKENS[3]
            @test store["t"] == TOKENS[3]
            put!(store, "e", TOKENS[1]; ttl=Millisecond(80))
            @test store["e"] == TOKENS[1]
            sleep(0.25)
            @test get(store, "e", nothing) === nothing
        end
    end

    @testset "JSON-encoded FileStore is human-readable" begin
        dir = mktempdir()
        store = FileStore{Token}(dir; codec=JSONCodec())
        store["tok"] = TOKENS[2]
        text = read(joinpath(dir, "tok"), String)
        @test occursin("at_2", text)
        @test JSON.parse(text)["value"]["expires_in"] == 7200
    end

    @testset "typed nested view drives JSON decoding" begin
        parent = FileStore{Any}(mktempdir(); codec=JSONCodec())
        root = PrefixedStore(parent, "root/")
        typed = PrefixedStore{Token}(root, "tokens/")

        typed["new"] = TOKENS[1]
        parent["root/tokens/existing"] = TOKENS[2]
        @test typed["new"] == TOKENS[1]
        @test typed["existing"] == TOKENS[2]
        @test get!(typed, "created", TOKENS[3]) == TOKENS[3]
        @test modify!(_ -> TOKENS[2], typed, "created") == TOKENS[2]
        @test Set(keys(typed)) == Set(["new", "existing", "created"])
    end
end
