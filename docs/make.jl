using Documenter, AbstractStores

makedocs(modules = [AbstractStores], sitename = "AbstractStores.jl",
         checkdocs = :exports)

deploydocs(repo = "github.com/JuliaServices/AbstractStores.jl.git", push_preview = true)
