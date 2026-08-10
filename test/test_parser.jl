@testitem "parse_args" begin
    positional, kwargs, flags = DevREPL.parse_args(["foo", "--tags=a,b", "--coverage", "bar"])
    @test positional == ["foo", "bar"]
    @test kwargs == Dict(:tags => "a,b")
    @test :coverage in flags && length(flags) == 1
end

@testitem "help lists the command groups" setup=[ReplHelper] begin
    out = ReplHelper.run_command("help")
    @test occursin("test pick", out)
    @test occursin("test -", out)
    @test occursin("test failed", out)
    @test occursin("lint [path]", out)
    @test occursin("format --check", out)
end

@testitem "legacy commands point at the test group" setup=[ReplHelper] begin
    out = ReplHelper.run_command("run --tags=foo")
    @test occursin("did you mean 'test'", out)
    out = ReplHelper.run_command("results")
    @test occursin("did you mean 'test results'", out)
    out = ReplHelper.run_command("procs")
    @test occursin("did you mean 'test procs'", out)
end

@testitem "unknown command" setup=[ReplHelper] begin
    out = ReplHelper.run_command("frobnicate")
    @test occursin("Unknown command: frobnicate", out)
    @test occursin("Type 'help'", out)
end

@testitem "empty input is a no-op" begin
    @test DevREPL.repl_parser("   ") === nothing
end

@testitem "test list finds the precompile test items" setup=[ReplHelper] begin
    out = ReplHelper.run_command("test list $(ReplHelper.PRECOMPILEDATA)")
    @test occursin("precompile pass", out)
    @test occursin("precompile fail", out)
    @test occursin("precompile error", out)
    @test occursin("3 test item(s) found.", out)
end

@testitem "test status and runs commands respond" setup=[ReplHelper] begin
    # Test items share a process, so runs from other test items may already be
    # in the history — only the command shape is asserted here.
    @test occursin("No background test run", ReplHelper.run_command("t st"))
    out = ReplHelper.run_command("test runs")
    @test occursin("No test runs in history", out) || occursin("run(s)", out)
end

@testitem "rerun without a previous run" setup=[ReplHelper] begin
    # A fresh test process has no recorded selection.
    DevREPL._last_selection[] = nothing
    out = ReplHelper.run_command("test -")
    @test occursin("No previous test run", out)
end
