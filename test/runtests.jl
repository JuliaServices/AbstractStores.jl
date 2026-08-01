using Test, Dates, AbstractStores

# A struct exercised through every codec, to prove stores are not string-only.
struct Token
    access::String
    expires_in::Int
    scopes::Vector{String}
end
Base.:(==)(a::Token, b::Token) =
    a.access == b.access && a.expires_in == b.expires_in && a.scopes == b.scopes

const TOKENS = [Token("at_1", 3600, ["read"]),
                Token("at_2", 7200, ["read", "write"]),
                Token("at_3", 60, String[])]

# verbose: with five backends running the same suite, the per-backend breakdown is
# the thing you actually want to see — including when everything passes.
@testset "AbstractStores" verbose = true begin
    include("core.jl")
    include("codecs.jl")
    include("backends.jl")
end
