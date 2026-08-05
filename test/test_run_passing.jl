@testitem "Run passing test items" setup=[TestHelpers] begin
    pkg_path = joinpath(TestHelpers.TESTDATA_DIR, "BasicPackage")
    discovered = TestHelpers.discover_test_items(pkg_path)

    # Filter to only the passing test items
    passing_items = filter(i -> i.label in ("add works", "greet works"), discovered.items)
    @test length(passing_items) >= 1

    result = TestHelpers.run_testrun(passing_items, discovered.setups, discovered)

    started_events = filter(e -> e.event == :started, result.events)
    passed_events = filter(e -> e.event == :passed, result.events)
    failed_events = filter(e -> e.event == :failed, result.events)
    errored_events = filter(e -> e.event == :errored, result.events)

    @test length(started_events) == length(passing_items)
    @test length(passed_events) == length(passing_items)
    @test length(failed_events) == 0
    @test length(errored_events) == 0

    # All passed items should have positive duration
    for e in passed_events
        @test e.duration > 0
    end

    # At least one test process should have been created
    created_events = filter(e -> e.event == :process_created, result.process_events)
    @test length(created_events) >= 1
end
