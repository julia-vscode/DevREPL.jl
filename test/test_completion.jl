@testitem "top-level completions" begin
    m, cur = DevREPL._devrepl_completions("")
    @test "test" in m && "lint" in m && "format" in m && "help" in m
    @test cur == ""

    m, cur = DevREPL._devrepl_completions("te")
    @test m == ["test", "test&"]
    @test cur == "te"
end

@testitem "test subcommand completions" begin
    m, _ = DevREPL._devrepl_completions("test ")
    for sub in ("pick", "failed", "list", "results", "runs", "procs", "kill", "plog")
        @test sub in m
    end

    m, cur = DevREPL._devrepl_completions("test pi")
    @test "pick" in m
    @test cur == "pi"
end

@testitem "flag completions" begin
    m, _ = DevREPL._devrepl_completions("test --")
    @test Set(m) == Set(["--tags=", "--workers=", "--timeout=", "--coverage"])

    m, _ = DevREPL._devrepl_completions("test results --")
    @test Set(m) == Set(["--name=", "--verbose", "--output"])

    m, _ = DevREPL._devrepl_completions("test runs --")
    @test m == ["--active"]

    m, _ = DevREPL._devrepl_completions("format --")
    @test m == ["--check"]
end

@testitem "directory completions" begin
    dir = mktempdir()
    mkpath(joinpath(dir, "subdir"))
    write(joinpath(dir, "afile.jl"), "")
    cd(dir) do
        m, _ = DevREPL._devrepl_completions("lint su")
        @test length(m) == 1
        @test startswith(m[1], "subdir")
        # Files are not offered, only directories
        m, _ = DevREPL._devrepl_completions("lint af")
        @test isempty(m)
    end
end

@testitem "subcommands without arguments complete nothing" begin
    m, _ = DevREPL._devrepl_completions("test failed ")
    @test isempty(m)
    m, _ = DevREPL._devrepl_completions("test status ")
    @test isempty(m)
end
