using Documenter, TestItemControllers

makedocs(
    modules = [TestItemControllers],
    sitename = "TestItemControllers.jl",
    warnonly = [:missing_docs],
    pages = [
        "Home" => "index.md",
        "Julia API" => "julia-api.md",
        "JSONRPC API" => "jsonrpc-api.md",
        "Internals" => "internals.md",
    ],
)

deploydocs(
    repo = "github.com/julia-testitems/TestItemControllers.jl.git",
)
