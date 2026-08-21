@testitem "Coverage collection" setup=[TestHelpers] begin
    # Coverage mode requires Julia >= 1.11
    if VERSION < v"1.11"
        @test_skip "Coverage mode requires Julia 1.11+"
    else
        using TestItemControllers: filepath2uri

        pkg_path = joinpath(TestHelpers.TESTDATA_DIR, "BasicPackage")
        discovered = TestHelpers.discover_test_items(pkg_path)

        passing_items = filter(i -> i.label == "add works", discovered.items)
        @test length(passing_items) == 1

        coverage_root = filepath2uri(joinpath(pkg_path, "src"))

        result = TestHelpers.run_testrun(
            passing_items, discovered.setups, discovered;
            mode="Coverage",
            coverage_root_uris=[coverage_root],
            timeout=600
        )

        passed_events = filter(e -> e.event == :passed, result.events)
        @test length(passed_events) == 1

        # Coverage data should be returned
        @test result.coverage !== nothing
        @test result.coverage isa Vector
        @test length(result.coverage) >= 1

        # Find the coverage entry for BasicPackage.jl
        src_file = joinpath(pkg_path, "src", "BasicPackage.jl")
        src_uri = filepath2uri(src_file)
        fc = filter(c -> c.uri == src_uri, result.coverage)
        @test length(fc) == 1

        cov = fc[1].coverage
        # Coverage vector should have a reasonable number of entries
        @test length(cov) >= 1

        # The `add` function (one-liner) should have been hit at least once
        has_hit = any(c -> c !== nothing && c > 0, cov)
        @test has_hit

        # Some lines should be nothing (not executable)
        has_nothing = any(c -> c === nothing, cov)
        @test has_nothing
    end
end

@testitem "Coverage with multiple test items" setup=[TestHelpers] begin
    if VERSION < v"1.11"
        @test_skip "Coverage mode requires Julia 1.11+"
    else
        using TestItemControllers: filepath2uri

        pkg_path = joinpath(TestHelpers.TESTDATA_DIR, "BasicPackage")
        discovered = TestHelpers.discover_test_items(pkg_path)

        items = filter(i -> i.label in ("add works", "greet works"), discovered.items)
        @test length(items) == 2

        coverage_root = filepath2uri(joinpath(pkg_path, "src"))

        result = TestHelpers.run_testrun(
            items, discovered.setups, discovered;
            mode="Coverage",
            coverage_root_uris=[coverage_root],
            timeout=600
        )

        passed_events = filter(e -> e.event == :passed, result.events)
        @test length(passed_events) == 2

        @test result.coverage !== nothing
        @test length(result.coverage) >= 1

        src_file = joinpath(pkg_path, "src", "BasicPackage.jl")
        src_uri = filepath2uri(src_file)
        fc = filter(c -> c.uri == src_uri, result.coverage)
        @test length(fc) == 1

        cov = fc[1].coverage
        src_lines = readlines(src_file)

        # Both greet() and add() lines should have been hit
        greet_line = findfirst(l -> occursin("greet()", l) && !occursin("export", l), src_lines)
        add_line = findfirst(l -> occursin("add(a, b)", l), src_lines)
        @test greet_line !== nothing
        @test add_line !== nothing
        @test length(cov) >= max(greet_line, add_line)
        @test cov[greet_line] !== nothing && cov[greet_line] > 0
        @test cov[add_line] !== nothing && cov[add_line] > 0
    end
end

@testitem "Coverage with failing test" setup=[TestHelpers] begin
    if VERSION < v"1.11"
        @test_skip "Coverage mode requires Julia 1.11+"
    else
        using TestItemControllers: filepath2uri

        pkg_path = joinpath(TestHelpers.TESTDATA_DIR, "BasicPackage")
        discovered = TestHelpers.discover_test_items(pkg_path)

        failing_items = filter(i -> i.label == "failing test", discovered.items)
        @test length(failing_items) == 1

        coverage_root = filepath2uri(joinpath(pkg_path, "src"))

        result = TestHelpers.run_testrun(
            failing_items, discovered.setups, discovered;
            mode="Coverage",
            coverage_root_uris=[coverage_root],
            timeout=600
        )

        # The test item should have failed (not errored/crashed)
        failed_events = filter(e -> e.event == :failed, result.events)
        @test length(failed_events) == 1

        # Coverage may be missing since the failing test doesn't use BasicPackage,
        # but the system must not crash or error.
        errored_events = filter(e -> e.event == :errored, result.events)
        @test length(errored_events) == 0
    end
end

@testitem "Coverage without coverage roots" setup=[TestHelpers] begin
    if VERSION < v"1.11"
        @test_skip "Coverage mode requires Julia 1.11+"
    else
        using TestItemControllers: filepath2uri

        # `juliati --coverage` never sends `coverageRootUris`. Feeding that `nothing` to
        # the test process's root filter used to throw a `MethodError`, which surfaced as
        # a spurious "errored" result for whichever item was running at the time.
        pkg_path = joinpath(TestHelpers.TESTDATA_DIR, "BasicPackage")
        discovered = TestHelpers.discover_test_items(pkg_path)

        passing_items = filter(i -> i.label == "add works", discovered.items)
        @test length(passing_items) == 1

        result = TestHelpers.run_testrun(
            passing_items, discovered.setups, discovered;
            mode="Coverage",
            coverage_root_uris=nothing,
            timeout=600
        )

        @test length(filter(e -> e.event == :errored, result.events)) == 0
        @test length(filter(e -> e.event == :passed, result.events)) == 1

        # With no root restriction every instrumented file is reported, so the package
        # source must be in there.
        @test result.coverage !== nothing
        src_uri = filepath2uri(joinpath(pkg_path, "src", "BasicPackage.jl"))
        @test length(filter(c -> c.uri == src_uri, result.coverage)) == 1
    end
end

@testitem "Coverage root filtering" setup=[TestHelpers] begin
    if VERSION < v"1.11"
        @test_skip "Coverage mode requires Julia 1.11+"
    else
        using TestItemControllers: filepath2uri

        pkg_path = joinpath(TestHelpers.TESTDATA_DIR, "BasicPackage")
        discovered = TestHelpers.discover_test_items(pkg_path)

        passing_items = filter(i -> i.label == "add works", discovered.items)
        @test length(passing_items) == 1

        # Point coverage root at a non-existent subfolder so nothing matches
        fake_root = filepath2uri(joinpath(pkg_path, "src", "nonexistent"))

        result = TestHelpers.run_testrun(
            passing_items, discovered.setups, discovered;
            mode="Coverage",
            coverage_root_uris=[fake_root],
            timeout=600
        )

        # Test should still pass
        passed_events = filter(e -> e.event == :passed, result.events)
        @test length(passed_events) == 1

        # But coverage should be missing since no files matched the root
        @test result.coverage === nothing
    end
end

@testitem "Coverage roots match whole path segments" setup=[TestHelpers] begin
    if VERSION < v"1.11"
        @test_skip "Coverage mode requires Julia 1.11+"
    else
        using TestItemControllers: filepath2uri

        pkg_path = joinpath(TestHelpers.TESTDATA_DIR, "BasicPackage")
        discovered = TestHelpers.discover_test_items(pkg_path)

        passing_items = filter(i -> i.label == "add works", discovered.items)
        @test length(passing_items) == 1

        # A root is a folder URI with no trailing slash, so a plain prefix test also
        # accepted anything whose name merely started with it: this truncated root used to
        # collect the whole of `src`, the same way a root of `<workspace>/Foo` collected
        # `<workspace>/Foo2`.
        truncated_root = String(chop(filepath2uri(joinpath(pkg_path, "src"))))

        result = TestHelpers.run_testrun(
            passing_items, discovered.setups, discovered;
            mode="Coverage",
            coverage_root_uris=[truncated_root],
            timeout=600
        )

        passed_events = filter(e -> e.event == :passed, result.events)
        @test length(passed_events) == 1
        @test result.coverage === nothing
    end
end

@testitem "Coverage is identical across repeated runs" setup=[TestHelpers] begin
    if VERSION < v"1.11"
        @test_skip "Coverage mode requires Julia 1.11+"
    else
        using TestItemControllers: filepath2uri

        # julia-vscode#3707: the same unchanged test item reported 100% coverage on the
        # first run and 27.27% on every later run. A pooled process already holds the
        # compiler's inference results for the code under test, so calls that can be folded
        # to a constant are never executed again and their line counters never move. Only a
        # process that has not run the code before measures it, hence coverage processes are
        # retired at the end of their test run instead of being pooled.
        pkg_path = joinpath(TestHelpers.TESTDATA_DIR, "BasicPackage")
        discovered = TestHelpers.discover_test_items(pkg_path)

        items = filter(i -> i.label == "add works", discovered.items)
        @test length(items) == 1

        coverage_root = filepath2uri(joinpath(pkg_path, "src"))

        result = TestHelpers.run_testrun(
            items, discovered.setups, discovered;
            mode="Coverage",
            coverage_root_uris=[coverage_root],
            n_runs=2,
            timeout=900
        )

        @test length(result.runs) == 2

        src_uri = filepath2uri(joinpath(pkg_path, "src", "BasicPackage.jl"))

        coverage_vectors = map(result.runs) do r
            @test r.coverage !== nothing
            fc = filter(c -> c.uri == src_uri, something(r.coverage, []))
            @test length(fc) == 1
            fc[1].coverage
        end

        @test coverage_vectors[1] == coverage_vectors[2]

        # Each run got its own process, i.e. the first run's process was not pooled.
        created = filter(e -> e.event == :process_created, result.process_events)
        @test length(created) == 2
    end
end

@testitem "Coverage includes @testmodule setup code" setup=[TestHelpers] begin
    if VERSION < v"1.11"
        @test_skip "Coverage mode requires Julia 1.11+"
    else
        using TestItemControllers: filepath2uri

        # A `@testmodule` used to be evaluated without a coverage window, so package code
        # only the setup exercised counted as uncovered.
        pkg_path = joinpath(TestHelpers.TESTDATA_DIR, "SetupPackage")
        discovered = TestHelpers.discover_test_items(pkg_path)

        items = filter(i -> i.label == "transform with module setup", discovered.items)
        @test length(items) == 1

        coverage_root = filepath2uri(joinpath(pkg_path, "src"))

        result = TestHelpers.run_testrun(
            items, discovered.setups, discovered;
            mode="Coverage",
            coverage_root_uris=[coverage_root],
            timeout=600
        )

        passed_events = filter(e -> e.event == :passed, result.events)
        @test length(passed_events) == 1

        src_file = joinpath(pkg_path, "src", "SetupPackage.jl")
        fc = filter(c -> c.uri == filepath2uri(src_file), something(result.coverage, []))
        @test length(fc) == 1

        cov = fc[1].coverage
        src_lines = readlines(src_file)

        # `get_config` is called only from the `ConfigSetup` testmodule, `transform` only
        # from the test item itself, so both being covered is what proves the setup's
        # coverage made it into the results.
        config_line = findfirst(l -> occursin("get_config() =", l), src_lines)
        transform_line = findfirst(l -> occursin("transform(x, config) =", l), src_lines)
        @test config_line !== nothing
        @test transform_line !== nothing
        @test length(cov) >= max(config_line, transform_line)
        @test cov[config_line] !== nothing && cov[config_line] > 0
        @test cov[transform_line] !== nothing && cov[transform_line] > 0
    end
end
