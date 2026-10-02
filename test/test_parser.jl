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

# Discovery is a folder walk, so `test` at the root of a monorepo or a Pkg `[workspace]`
# covers every package below it. `--packages` is how a run is narrowed back to one member
# without paying to activate and precompile the others.
@testitem "--packages and --exclude-packages select by package" begin
    item(pkg) = (filename="f.jl", name="n", tags=Symbol[], package_name=pkg)

    @test DevREPL._package_filter(Dict{Symbol,String}()) == (nothing, nothing)

    include_only, description = DevREPL._package_filter(Dict(:packages => "A,B"))
    @test include_only(item("A"))
    @test include_only(item("B"))
    @test !include_only(item("C"))
    # Package names are case sensitive, and an item belonging to no package is not "A".
    @test !include_only(item("a"))
    @test !include_only(item(""))
    @test occursin("packages A, B", description)

    exclude_only, description = DevREPL._package_filter(Dict(Symbol("exclude-packages") => "C"))
    @test exclude_only(item("A"))
    @test !exclude_only(item("C"))
    # Without --packages, an item belonging to no package still runs.
    @test exclude_only(item(""))
    @test occursin("not packages C", description)

    # Include first, then exclude.
    both, _ = DevREPL._package_filter(Dict(:packages => "A,B", Symbol("exclude-packages") => "B"))
    @test both(item("A"))
    @test !both(item("B"))
    @test !both(item("C"))

    # An empty entry is a typo, not "no package".
    @test_throws ArgumentError DevREPL._package_filter(Dict(:packages => "A,,B"))
    @test_throws ArgumentError DevREPL._package_filter(Dict(:packages => ""))
    @test_throws ArgumentError DevREPL._package_filter(Dict(Symbol("exclude-packages") => "A,"))
end

@testitem "_build_run_kwargs composes the package selection with the other filters" begin
    item(; name="n", pkg="A", tags=Symbol[]) = (filename="f.jl", name=name, tags=tags, package_name=pkg)

    _, run_kwargs = DevREPL._build_run_kwargs(String["--packages=A"])
    @test run_kwargs[:filter](item(pkg="A"))
    @test !run_kwargs[:filter](item(pkg="B"))
    @test occursin("packages A", run_kwargs[:filter_description])

    # Every given criterion has to hold, and the description names all of them.
    _, run_kwargs = DevREPL._build_run_kwargs(String["--packages=A", "--name=slow"])
    @test run_kwargs[:filter](item(name="slow one", pkg="A"))
    @test !run_kwargs[:filter](item(name="slow one", pkg="B"))
    @test !run_kwargs[:filter](item(name="fast one", pkg="A"))
    @test occursin("name \"slow\"", run_kwargs[:filter_description])
    @test occursin("packages A", run_kwargs[:filter_description])

    # Absent the flags, no filter is installed at all.
    _, run_kwargs = DevREPL._build_run_kwargs(String[])
    @test !haskey(run_kwargs, :filter)
end

@testitem "--packages reaches a real run" setup=[ReplHelper] begin
    out = ReplHelper.run_command("test run $(ReplHelper.PRECOMPILEDATA) --packages=PrecompileData --name=pass")
    @test occursin("1 tests ran", out)

    # A package that is not there selects nothing, and says so rather than looking like a
    # clean run of an empty suite.
    out = ReplHelper.run_command("test run $(ReplHelper.PRECOMPILEDATA) --packages=NoSuchPackage")
    @test occursin("No test item matched the filter", out)
    @test occursin("packages NoSuchPackage", out)
end

@testitem "test list honours --packages" setup=[ReplHelper] begin
    out = ReplHelper.run_command("test list $(ReplHelper.PRECOMPILEDATA) --packages=PrecompileData")
    @test occursin("precompile pass", out)

    out = ReplHelper.run_command("test list $(ReplHelper.PRECOMPILEDATA) --packages=NoSuchPackage")
    @test occursin("No test items found", out)

    out = ReplHelper.run_command("test list $(ReplHelper.PRECOMPILEDATA) --packages=A,,B")
    @test occursin("empty package name", out)
end

# The timeout is opt-in: how long a test item legitimately takes is not something
# DevREPL can know, and a fired timeout kills the test process and errors the item.
@testitem "--timeout is opt-in and accepts an opt-out spelling" begin
    @test DevREPL._parse_timeout("30") == 30.0
    @test DevREPL._parse_timeout("2.5") == 2.5
    @test DevREPL._parse_timeout("none") === nothing
    @test DevREPL._parse_timeout("off") === nothing
    @test_throws ArgumentError DevREPL._parse_timeout("0")
    @test_throws ArgumentError DevREPL._parse_timeout("-5")
    @test_throws ArgumentError DevREPL._parse_timeout("soon")

    # Absent the flag, no deadline reaches the work units at all.
    _, run_kwargs = DevREPL._build_run_kwargs(String[])
    @test !haskey(run_kwargs, :timeout)
end
