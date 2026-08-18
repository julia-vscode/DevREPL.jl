@testitem "parse_args" begin
    positional, kwargs, flags = DevREPL.parse_args(["foo", "--tags=a,b", "--coverage", "bar"])
    @test positional == ["foo", "bar"]
    @test kwargs == Dict(:tags => "a,b")
    @test :coverage in flags && length(flags) == 1
end

@testitem "help lists the command groups" setup=[ReplHelper] begin
    out = ReplHelper.run_command("help")
    @test occursin("test run", out)
    @test occursin("test pick", out)
    @test occursin("test repeat", out)
    @test occursin("test failed", out)
    @test occursin("lint [path]", out)
    @test occursin("format --check", out)
end

@testitem "unknown command" setup=[ReplHelper] begin
    out = ReplHelper.run_command("frobnicate")
    @test occursin("Unknown command: frobnicate", out)
    @test occursin("Type 'help'", out)
end

# A subcommand is mandatory. This is the structural guard on the bug where
# `test run` was not a subcommand, fell through to a catch-all, and was silently
# reinterpreted as a filter on the test item name "run" — selecting nothing.
@testitem "test requires a subcommand" setup=[ReplHelper] begin
    out = ReplHelper.run_command("test")
    @test occursin("needs a subcommand", out)
    @test occursin("test run", out)
end

@testitem "unknown test subcommands never reach the runner" setup=[ReplHelper] begin
    for word in ("lst", "frobnicate", "runs", "-", "plog")
        out = ReplHelper.run_command("test $word")
        @test occursin("Unknown test command: $word", out)
        # The giveaway that it started a run instead of erroring.
        @test !occursin("Discovered", out)
    end
end

@testitem "retired top-level spellings are gone" setup=[ReplHelper] begin
    for cmd in ("test&", "@", "run", "results", "procs")
        out = ReplHelper.run_command(cmd)
        @test occursin("Unknown command: $cmd", out)
    end
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

@testitem "test status and history commands respond" setup=[ReplHelper] begin
    # Test items share a process, so runs from other test items may already be
    # in the history — only the command shape is asserted here.
    ReplHelper.reset_bg_runs!()
    @test occursin("No test runs in progress", ReplHelper.run_command("t st"))
    out = ReplHelper.run_command("test history")
    @test occursin("No test runs in history", out) || occursin("run(s)", out)
end

@testitem "repeat without a previous run" setup=[ReplHelper] begin
    # A fresh test process has no recorded selection.
    DevREPL._last_selection[] = nothing
    out = ReplHelper.run_command("test repeat")
    @test occursin("No previous test run", out)
end

@testitem "test run selects everything by default" setup=[ReplHelper] begin
    out = ReplHelper.run_command("test run $(ReplHelper.PRECOMPILEDATA)")
    @test occursin("Discovered 3 test item(s)", out)
    # No filter, so nothing is narrowed away and no selection line appears.
    @test !occursin("Selected", out)
    @test occursin("3 tests ran", out)
end

@testitem "a filter that matches nothing says so" setup=[ReplHelper] begin
    out = ReplHelper.run_command("test run $(ReplHelper.PRECOMPILEDATA) --name=zzzznomatch")
    # The counts must show detection succeeded and the filter did the excluding.
    @test occursin("Discovered 3 test item(s)", out)
    @test occursin("Selected 0 of 3", out)
    @test occursin("zzzznomatch", out)
end

@testitem "name filter selects a subset" setup=[ReplHelper] begin
    out = ReplHelper.run_command("test run $(ReplHelper.PRECOMPILEDATA) --name=pass")
    @test occursin("Selected 1 of 3", out)
    @test occursin("1 tests ran", out)
end

# `kill_test_processes` empties the process pool but keeps the session, so the
# next run simply relaunches what it needs — `test kill` must not brick the session.
@testitem "a run still works after killing the test processes" setup=[ReplHelper] begin
    ReplHelper.run_command("test run $(ReplHelper.PRECOMPILEDATA) --name=pass")
    DevREPL.kill_test_processes()
    @test isopen(DevREPL.get_session())
    out = ReplHelper.run_command("test run $(ReplHelper.PRECOMPILEDATA) --name=pass")
    @test occursin("1 tests ran", out)
end
