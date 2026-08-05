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
