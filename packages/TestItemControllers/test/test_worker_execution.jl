@testitem "Skip by literal" setup=[TestHelpers] begin
    pkg_path = joinpath(TestHelpers.TESTDATA_DIR, "BasicPackage")
    discovered = TestHelpers.discover_test_items(pkg_path)

    items = [TestHelpers.with_skip(discovered.items[1], true)]

    result = TestHelpers.run_testrun(items, discovered.setups, discovered)

    skipped_events = filter(e -> e.event == :skipped, result.events)
    @test length(skipped_events) == 1
    @test skipped_events[1].reason == "true"
    @test isempty(filter(e -> e.event in (:passed, :failed, :errored), result.events))
end

@testitem "Skip by literal false runs the item" setup=[TestHelpers] begin
    pkg_path = joinpath(TestHelpers.TESTDATA_DIR, "BasicPackage")
    discovered = TestHelpers.discover_test_items(pkg_path)

    items = [TestHelpers.with_skip(discovered.items[1], false)]

    result = TestHelpers.run_testrun(items, discovered.setups, discovered)

    @test isempty(filter(e -> e.event == :skipped, result.events))
    @test length(filter(e -> e.event in (:passed, :failed), result.events)) == 1
end

@testitem "Skip by expression" setup=[TestHelpers] begin
    pkg_path = joinpath(TestHelpers.TESTDATA_DIR, "BasicPackage")
    discovered = TestHelpers.discover_test_items(pkg_path)

    # An expression only the test process can answer, which is the whole point of evaluating
    # `skip` there rather than on the controller.
    items = [TestHelpers.with_skip(discovered.items[1], "VERSION >= v\"1.0\"")]

    result = TestHelpers.run_testrun(items, discovered.setups, discovered)

    skipped_events = filter(e -> e.event == :skipped, result.events)
    @test length(skipped_events) == 1
    @test skipped_events[1].reason == "VERSION >= v\"1.0\""
end

@testitem "Skip expression source text is re-parenthesized" setup=[TestHelpers] begin
    # JuliaSyntax records parentheses as trivia, so `skip=(a ? b : c)` reaches the test
    # process as `a ? b : c` with the parentheses gone. Spliced in bare, the surrounding
    # context reassociates it; the test process therefore always re-parenthesizes.
    pkg_path = joinpath(TestHelpers.TESTDATA_DIR, "BasicPackage")
    discovered = TestHelpers.discover_test_items(pkg_path)

    # `false ? error("boom") : true` is `true` when parsed as one expression, and a parse
    # error or a thrown `error` under any reassociation.
    items = [TestHelpers.with_skip(discovered.items[1], "false ? error(\"boom\") : true")]

    result = TestHelpers.run_testrun(items, discovered.setups, discovered)

    skipped_events = filter(e -> e.event == :skipped, result.events)
    @test length(skipped_events) == 1
    @test isempty(filter(e -> e.event == :errored, result.events))
end

@testitem "Skip expression with a trailing comment" setup=[TestHelpers] begin
    # The re-parenthesization puts the closing paren on its own line so a trailing line
    # comment in the source text cannot swallow it.
    pkg_path = joinpath(TestHelpers.TESTDATA_DIR, "BasicPackage")
    discovered = TestHelpers.discover_test_items(pkg_path)

    items = [TestHelpers.with_skip(discovered.items[1], "true # always")]

    result = TestHelpers.run_testrun(items, discovered.setups, discovered)

    @test length(filter(e -> e.event == :skipped, result.events)) == 1
end

@testitem "Skip expression that throws errors the item" setup=[TestHelpers] begin
    pkg_path = joinpath(TestHelpers.TESTDATA_DIR, "BasicPackage")
    discovered = TestHelpers.discover_test_items(pkg_path)

    items = [TestHelpers.with_skip(discovered.items[1], "error(\"cannot decide\")")]

    result = TestHelpers.run_testrun(items, discovered.setups, discovered)

    errored_events = filter(e -> e.event == :errored, result.events)
    @test length(errored_events) == 1
    @test occursin("skip", errored_events[1].messages[1].message)
    @test isempty(filter(e -> e.event == :skipped, result.events))
end

@testitem "Skip expression that is not a Bool errors the item" setup=[TestHelpers] begin
    pkg_path = joinpath(TestHelpers.TESTDATA_DIR, "BasicPackage")
    discovered = TestHelpers.discover_test_items(pkg_path)

    items = [TestHelpers.with_skip(discovered.items[1], "42")]

    result = TestHelpers.run_testrun(items, discovered.setups, discovered)

    errored_events = filter(e -> e.event == :errored, result.events)
    @test length(errored_events) == 1
    @test occursin("must evaluate to a `Bool`", errored_events[1].messages[1].message)
end

@testitem "Perf stats are reported for a passing item" setup=[TestHelpers] begin
    pkg_path = joinpath(TestHelpers.TESTDATA_DIR, "BasicPackage")
    discovered = TestHelpers.discover_test_items(pkg_path)

    # One passing item is all this needs. Running the whole package dragged in the 60s
    # sleeper and the deliberate crash items, which on a slow runner pushed the run past its
    # timeout — leaving no passed events and turning this into a BoundsError on the indexing
    # below rather than a readable failure.
    items = filter(i -> i.label == "add works", discovered.items)
    result = TestHelpers.run_testrun(items, discovered.setups, discovered)

    passed_events = filter(e -> e.event == :passed, result.events)
    @test length(passed_events) == 1
    # Stop here rather than index an empty vector: the assertion above is the real signal.
    if isempty(passed_events)
        return
    end

    perf = passed_events[1].perf
    @test perf !== nothing
    @test perf.elapsed !== nothing && perf.elapsed >= 0
    @test perf.bytes !== nothing && perf.bytes >= 0
    @test perf.allocs !== nothing && perf.allocs >= 0
    @test perf.gctime !== nothing && perf.gctime >= 0

    # Compile timings come from `Base.cumulative_compile_timing`, which does not exist on
    # every Julia version the test process supports. The contract is that they are `nothing`
    # there rather than an error — so the only assertion that holds everywhere is that the
    # item still produced a normal result, which the `passed` event above already shows.
    if VERSION >= v"1.8"
        @test perf.compile_time !== nothing
        @test perf.recompile_time !== nothing
    end
end

@testitem "Perf stats degrade instead of erroring on a Julia without compile timing" setup=[TestHelpers] begin
    # `Base.cumulative_compile_timing` only exists from 1.8 on, and the test process supports
    # every version back to 1.0. The degradation contract is that the compile timings come
    # back `nothing` and the item still runs — not that anything throws.
    installed = try
        TestHelpers.installed_juliaup_channels()
    catch err
        Set{String}()
    end

    if "1.6" in installed
        pkg_path = joinpath(TestHelpers.TESTDATA_DIR, "BasicPackage")
        discovered = TestHelpers.discover_test_items(pkg_path)
        items = filter(i -> i.label == "add works", discovered.items)

        # Deliberately left on the default depot: the "Julia 1.6 platform" item in
        # test_julia_versions.jl writes to a private layered depot instead, so the two never
        # contend on the same `compiled/v1.6` cache files even when CI runs them side by side.
        result = TestHelpers.run_testrun(items, discovered.setups, discovered; julia_cmd="julia", julia_args=["+1.6"],
            # Same reason as `check_julia_version`: launching an old Julia into a cold depot
            # is unbounded on the 32-bit Windows runner.
            timeout=1800)

        passed_events = filter(e -> e.event == :passed, result.events)
        @test length(passed_events) == 1

        perf = passed_events[1].perf
        @test perf !== nothing
        @test perf.compile_time === nothing
        @test perf.recompile_time === nothing
        # The parts that do not depend on 1.8 internals are still measured.
        @test perf.elapsed !== nothing
        @test perf.bytes !== nothing
    else
        @info "Skipping the old-Julia perf degradation check: juliaup channel 1.6 is not installed."
        @test true
    end
end

@testitem "Perf stats are reported for failing and erroring items" setup=[TestHelpers] begin
    pkg_path = joinpath(TestHelpers.TESTDATA_DIR, "BasicPackage")
    discovered = TestHelpers.discover_test_items(pkg_path)

    items = filter(i -> i.label in ("failing test", "erroring test"), discovered.items)
    @test length(items) == 2

    result = TestHelpers.run_testrun(items, discovered.setups, discovered)

    terminal = filter(e -> e.event in (:failed, :errored), result.events)
    @test length(terminal) == 2
    @test all(e -> e.perf !== nothing, terminal)
    @test all(e -> e.perf.elapsed !== nothing, terminal)
end

@testitem "Setup output is replayed onto every dependent item" setup=[TestHelpers] begin
    pkg_path = joinpath(TestHelpers.TESTDATA_DIR, "SetupOutputPackage")
    discovered = TestHelpers.discover_test_items(pkg_path)

    items = filter(i -> startswith(i.label, "chatty consumer"), discovered.items)
    @test length(items) == 3

    result = TestHelpers.run_testrun(items, discovered.setups, discovered)

    passed_events = filter(e -> e.event == :passed, result.events)
    @test length(passed_events) == 3

    # All three items see the setup's output, not just whichever one triggered the single
    # evaluation, and it is fenced with a header naming the setup (analysis A.3).
    for item in items
        output = get(result.outputs, item.id, "")
        @test occursin("CHATTY_SETUP_MARKER", output)
        @test occursin("output from @testmodule ChattySetup", output)
    end
end

@testitem "Setup output is replayed again on a pooled process" setup=[TestHelpers] begin
    pkg_path = joinpath(TestHelpers.TESTDATA_DIR, "SetupOutputPackage")
    discovered = TestHelpers.discover_test_items(pkg_path)

    items = filter(i -> startswith(i.label, "chatty consumer"), discovered.items)

    # Two runs against one controller: the second reuses the warm process, on which the
    # setup is already evaluated and would previously have printed nothing at all.
    result = TestHelpers.run_testrun(items, discovered.setups, discovered; n_runs=2)

    @test length(result.runs) == 2

    for run in result.runs
        @test length(filter(e -> e.event == :passed, run.events)) == 3
        for item in items
            output = get(run.outputs, item.id, "")
            @test occursin("CHATTY_SETUP_MARKER", output)
        end
    end
end

@testitem "Replayed setup output is capped" setup=[TestHelpers] begin
    pkg_path = joinpath(TestHelpers.TESTDATA_DIR, "SetupOutputPackage")
    discovered = TestHelpers.discover_test_items(pkg_path)

    items = filter(i -> i.label == "loud consumer", discovered.items)
    @test length(items) == 1

    result = TestHelpers.run_testrun(items, discovered.setups, discovered)

    @test length(filter(e -> e.event == :passed, result.events)) == 1

    output = get(result.outputs, items[1].id, "")
    @test occursin("LOUD_LINE_1_", output)
    @test occursin("bytes of setup output truncated", output)
    # The cap is 32 KiB; the fence and the CRLF translation add a little on top of it.
    @test ncodeunits(output) < 48 * 1024
    @test !occursin("LOUD_LINE_2000_", output)
end
