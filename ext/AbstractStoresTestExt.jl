module AbstractStoresTestExt

using Test, Dates
using AbstractStores
using AbstractStores: AbstractStore, supportsttl, supportslisting, isatomic, sweep!, modify!

# The case pair ("case"/"CASE") and accent pair ("cafe"/"café") are load-bearing:
# a backend whose key comparison folds case or accents (MySQL's default
# collation does both) silently merges them into one entry.
const TRICKY_KEYS = ["a/b/c", "with space", "ünïcødé", "colon:sep", "dot.dot",
                     "under_score", "dash-dash", "%percent", "plus+eq=", "~tilde",
                     "case", "CASE", "cafe", "café"]

function AbstractStores.runstoretests(makestore, values::AbstractVector;
                       name::AbstractString="", concurrency::Bool=true,
                       trickykeys::AbstractVector=TRICKY_KEYS)
    length(values) >= 3 || throw(ArgumentError("need at least 3 distinct test values"))
    allunique(values) || throw(ArgumentError("test values must be distinct"))
    label = isempty(name) ? string(typeof(makestore())) : name
    v1, v2, v3 = values[1], values[2], values[3]

    @testset "AbstractStore conformance: $label" begin
        @testset "traits" begin
            store = makestore()
            @test store isa AbstractStore
            @test Base.keytype(store) === String
            @test eltype(store) === valtype(store)
            @test v1 isa eltype(store)
            @test supportsttl(store) isa Bool
            @test supportslisting(store) isa Bool
            @test isatomic(store) isa Bool
        end

        @testset "get / put! / delete!" begin
            store = makestore()
            @test get(store, "missing", nothing) === nothing
            @test get(store, "missing", :sentinel) === :sentinel
            @test get(() -> :computed, store, "missing") === :computed
            @test !haskey(store, "missing")
            @test_throws KeyError store["missing"]

            @test put!(store, "a", v1) === store
            @test store["a"] == v1
            @test get(store, "a", nothing) == v1
            @test get(() -> :computed, store, "a") == v1
            @test haskey(store, "a")

            # overwrite
            put!(store, "a", v2)
            @test store["a"] == v2

            # setindex! shorthand
            store["b"] = v3
            @test store["b"] == v3
            @test store["a"] == v2      # unrelated key untouched

            @test delete!(store, "a") === store
            @test !haskey(store, "a")
            @test get(store, "a", nothing) === nothing
            @test store["b"] == v3
            @test delete!(store, "a") === store   # deleting an absent key is fine
        end

        @testset "key handling" begin
            store = makestore()
            # keys the interface must survive: separators, spaces, unicode, symbols
            tricky = trickykeys
            for (i, k) in enumerate(tricky)
                put!(store, k, values[mod1(i, length(values))])
            end
            for (i, k) in enumerate(tricky)
                @test store[k] == values[mod1(i, length(values))]
            end
            # distinct keys must not collide after any internal encoding
            if supportslisting(store)
                @test length(collect(keys(store))) == length(tricky)
            end
            # A path-traversal-shaped key must never reach outside the store.
            # Storing it verbatim is the good outcome and refusing it is an
            # acceptable one; silently writing to "escape" is the bug.
            stored = try
                put!(store, "../escape", v1)
                true
            catch
                false
            end
            stored && @test store["../escape"] == v1
            @test get(store, "escape", nothing) === nothing
        end

        @testset "pop!" begin
            store = makestore()
            put!(store, "once", v1)
            @test pop!(store, "once", nothing) == v1
            @test !haskey(store, "once")
            @test pop!(store, "once", nothing) === nothing
            @test_throws KeyError pop!(store, "once")

            put!(store, "keep", v2)
            put!(store, "take", v3)
            @test pop!(store, "take") == v3
            @test store["keep"] == v2
        end

        @testset "get!" begin
            store = makestore()
            @test get!(store, "k", v1) == v1
            @test store["k"] == v1
            @test get!(store, "k", v2) == v1      # existing value wins
            @test store["k"] == v1

            calls = Ref(0)
            @test get!(store, "lazy") do
                calls[] += 1
                v3
            end == v3
            @test calls[] == 1
            @test get!(store, "lazy") do
                calls[] += 1
                v2
            end == v3
            @test calls[] == 1                    # f not called when present
        end

        @testset "modify!" begin
            store = makestore()
            @test modify!(old -> (@test(old === nothing); v1), store, "m") == v1
            @test store["m"] == v1
            @test modify!(old -> (@test(old == v1); v2), store, "m") == v2
            @test store["m"] == v2
            @test modify!(_ -> nothing, store, "m") === nothing
            @test !haskey(store, "m")

            # do-block form
            modify!(store, "m") do old
                old === nothing ? v3 : old
            end
            @test store["m"] == v3
        end

        if supportslisting(makestore())
            @testset "keys / length / empty! / pairs" begin
                store = makestore()
                @test isempty(store)
                @test length(store) == 0
                @test isempty(collect(keys(store)))

                put!(store, "ns1/a", v1)
                put!(store, "ns1/b", v2)
                put!(store, "ns2/c", v3)

                @test length(store) == 3
                @test !isempty(store)
                @test Set(keys(store)) == Set(["ns1/a", "ns1/b", "ns2/c"])
                @test Set(keys(store; prefix="ns1/")) == Set(["ns1/a", "ns1/b"])
                @test Set(keys(store; prefix="ns2/")) == Set(["ns2/c"])
                @test isempty(collect(keys(store; prefix="nope")))
                # not a Set: the suite must not require values to be hashable
                @test collect(pairs(store; prefix="ns2/")) == ["ns2/c" => v3]

                delete!(store, "ns1/a")
                @test Set(keys(store)) == Set(["ns1/b", "ns2/c"])

                empty!(store; prefix="ns1/")
                @test Set(keys(store)) == Set(["ns2/c"])

                @test empty!(store) === store
                @test isempty(store)
                @test length(store) == 0

                # prefix matching is byte-exact, never case-folded — a backend
                # matching case-insensitively (SQLite LIKE, MySQL's default
                # collation) would list, and worse *empty!*, a sibling namespace.
                # Gated on the case pair so a harness that had to drop it from
                # `trickykeys` (e.g. Minio storing objects on a case-insensitive
                # filesystem) skips this consistently.
                if "case" in trickykeys && "CASE" in trickykeys
                    put!(store, "Case/upper", v1)
                    put!(store, "case/lower", v2)
                    @test Set(keys(store; prefix="case/")) == Set(["case/lower"])
                    @test Set(keys(store; prefix="Case/")) == Set(["Case/upper"])
                    empty!(store; prefix="case/")
                    @test haskey(store, "Case/upper")
                    @test !haskey(store, "case/lower")
                    empty!(store)
                end
            end
        end

        @testset "ttl" begin
            store = makestore()
            if supportsttl(store)
                put!(store, "soon", v1; ttl=Dates.Millisecond(250))
                @test store["soon"] == v1
                @test haskey(store, "soon")
                supportslisting(store) && @test "soon" in collect(keys(store))

                put!(store, "later", v2; ttl=Dates.Hour(1))
                put!(store, "never", v3)

                sleep(0.6)
                @test get(store, "soon", nothing) === nothing
                @test !haskey(store, "soon")
                @test_throws KeyError store["soon"]
                @test store["later"] == v2
                @test store["never"] == v3
                if supportslisting(store)
                    @test !("soon" in collect(keys(store)))
                    @test Set(keys(store)) == Set(["later", "never"])
                end

                # an expired key behaves as absent for the atomic ops too
                put!(store, "gone", v1; ttl=Dates.Millisecond(100))
                sleep(0.4)
                @test pop!(store, "gone", nothing) === nothing
                put!(store, "gone2", v1; ttl=Dates.Millisecond(100))
                sleep(0.4)
                @test get!(store, "gone2", v2) == v2

                # rewriting without a ttl clears the old deadline
                put!(store, "refreshed", v1; ttl=Dates.Millisecond(200))
                put!(store, "refreshed", v2)
                sleep(0.5)
                @test get(store, "refreshed", nothing) == v2

                # ...but get! on a live key must NOT: returning the value you were
                # handed means "unchanged", so the original deadline still stands
                put!(store, "leased", v1; ttl=Dates.Millisecond(300))
                @test get!(store, "leased", v2) == v1
                @test modify!(old -> old, store, "leased") == v1
                sleep(0.6)
                @test get(store, "leased", nothing) === nothing

                @test sweep!(store) isa Integer
                @test_throws ArgumentError put!(store, "bad", v1; ttl=0)
                @test_throws ArgumentError put!(store, "bad", v1; ttl=Dates.Second(-1))
            else
                # must reject, not silently ignore
                @test_throws ArgumentError put!(store, "k", v1; ttl=Dates.Second(30))
                @test sweep!(store) == 0
            end
        end

        if concurrency && isatomic(makestore())
            @testset "concurrency" begin
                store = makestore()

                # exactly one task may win a pop!
                put!(store, "prize", v1)
                winners = Threads.Atomic{Int}(0)
                @sync for _ in 1:20
                    Threads.@spawn begin
                        pop!(store, "prize", nothing) === nothing || Threads.atomic_add!(winners, 1)
                    end
                end
                @test winners[] == 1

                # get! is first-writer-wins: everyone sees the same value
                store2 = makestore()
                seen = Vector{Any}(undef, 20)
                @sync for i in 1:20
                    Threads.@spawn begin
                        seen[i] = get!(store2, "shared") do
                            sleep(0.001)
                            values[mod1(i, length(values))]
                        end
                    end
                end
                @test all(==(seen[1]), seen)
                @test store2["shared"] == seen[1]

                # modify! does not lose updates
                if Int <: eltype(store)
                    store3 = makestore()
                    put!(store3, "counter", 0)
                    @sync for _ in 1:50
                        Threads.@spawn modify!(n -> n + 1, store3, "counter")
                    end
                    @test store3["counter"] == 50
                end
            end
        end
    end
    return nothing
end

AbstractStores.runstoretests(makestore; kw...) = AbstractStores.runstoretests(makestore, ["one", "two", "three"]; kw...)

end # module
