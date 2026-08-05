@testitem "Multiple processes" setup=[TestHelpers] begin
    pkg_path = joinpath(TestHelpers.TESTDATA_DIR, "BasicPackage")
    discovered = TestHelpers.discover_test_items(pkg_path)

    # Use only the passing items to avoid complications with crashes
    passing_items = filter(i -> i.label in ("add works", "greet works"), discovered.items)
    @test length(passing_items) >= 2

    result = TestHelpers.run_testrun(passing_items, discovered.setups, discovered; max_procs=2)

    # All items should reach terminal state
    started = filter(e -> e.event == :started, result.events)
    passed = filter(e -> e.event == :passed, result.events)
    failed = filter(e -> e.event == :failed, result.events)
    errored = filter(e -> e.event == :errored, result.events)

    @test length(started) == length(passing_items)
    terminal_count = length(passed) + length(failed) + length(errored)
    @test terminal_count == length(passing_items)
    @test length(passed) == length(passing_items)

    # Multiple processes should have been created
    created = filter(e -> e.event == :process_created, result.process_events)
    @test length(created) >= 2

    # Each process should have status change events
    process_ids = Set(e.id for e in created)
    for pid in process_ids
        status_events = filter(e -> e.event == :status_changed && e.id == pid, result.process_events)
        @test length(status_events) >= 1
    end
end
