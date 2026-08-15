using AbstractStores
using Dates

function trim_assert(condition::Bool, message::AbstractString)::Nothing
    condition || error(message)
    return nothing
end

function trim_memory_store()::Nothing
    store = AbstractStores.MemoryStore{Int}()
    AbstractStores.checkstore(store; ttl=true, atomic=true, listing=true)

    put!(store, "counter", 1; ttl=Minute(5))
    trim_assert(get(store, "counter", 0) == 1, "memory get")
    trim_assert(haskey(store, "counter"), "memory haskey")
    trim_assert(AbstractStores.modify!(value -> value + 1, store, "counter") == 2,
                "memory modify")
    trim_assert(get!(store, "counter", 99) == 2, "memory get existing")
    trim_assert(get!(store, "created", 3) == 3, "memory get or create")
    trim_assert(Set(keys(store; prefix="count")) == Set(["counter"]),
                "memory prefix listing")
    trim_assert(pop!(store, "counter", 0) == 2, "memory pop")
    trim_assert(!haskey(store, "counter"), "memory pop removes value")
    trim_assert(AbstractStores.sweep!(store) == 0, "memory sweep")
    empty!(store)
    trim_assert(isempty(store), "memory empty")
    return nothing
end

function trim_prefixed_store()::Nothing
    backend = AbstractStores.MemoryStore{String}()
    tokens = AbstractStores.PrefixedStore(backend, "oauth/tokens/")
    codes = AbstractStores.PrefixedStore(backend, "oauth/codes/")
    tokens["alice"] = "token-1"
    codes["grant"] = "code-1"

    trim_assert(tokens["alice"] == "token-1", "prefixed get")
    trim_assert(collect(keys(tokens)) == ["alice"], "prefixed keys")
    empty!(codes)
    trim_assert(isempty(codes), "prefixed empty")
    trim_assert(tokens["alice"] == "token-1", "prefix isolation")
    return nothing
end

function trim_typed_file_view()::Nothing
    backend = AbstractStores.FileStore{Any}(mktempdir(); codec=AbstractStores.RawCodec())
    root = AbstractStores.PrefixedStore(backend, "root/")
    values = AbstractStores.PrefixedStore{String}(root, "values/")

    put!(values, "one", "1")
    trim_assert(get(values, "one", "0") == "1", "typed file get")
    trim_assert(get!(values, "one", "9") == "1", "typed file get existing")
    trim_assert(get!(values, "two", "2") == "2", "typed file get or create")
    trim_assert(AbstractStores.modify!(value -> value * "+", values, "two") == "2+",
                "typed file modify")
    trim_assert(Set(keys(values)) == Set(["one", "two"]), "typed file keys")
    return nothing
end

function run_abstractstores_trim()::Nothing
    trim_memory_store()
    trim_prefixed_store()
    trim_typed_file_view()
    return nothing
end

function @main(args::Vector{String})::Cint
    _ = args
    run_abstractstores_trim()
    return 0
end

Base.Experimental.entrypoint(main, (Vector{String},))
