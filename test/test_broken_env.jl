@testitem "Broken environment activation errors all test items" setup=[TestHelpers] begin
    pkg_path = joinpath(TestHelpers.TESTDATA_DIR, "BrokenEnvPackage")
    discovered = TestHelpers.discover_test_items(pkg_path)

    @test length(discovered.items) >= 1

    result = TestHelpers.run_testrun(discovered)

    # All items should have errored (not passed, not hung)
    errored_events = filter(e -> e.event == :errored, result.events)
    passed_events = filter(e -> e.event == :passed, result.events)
    failed_events = filter(e -> e.event == :failed, result.events)

    @test length(errored_events) == length(discovered.items)
    @test length(passed_events) == 0
    @test length(failed_events) == 0

    # Error messages should contain useful diagnostics about the activation failure
    for e in errored_events
        @test length(e.messages) >= 1
        msg = e.messages[1].message
        @test occursin("activation failed", msg) || occursin("activation failed", lowercase(msg))
    end

    # Processes should have been cleaned up
    terminated_events = filter(e -> e.event == :process_terminated, result.process_events)
    @test length(terminated_events) >= 1
end

@testitem "Broken env with multiple processes errors all items" setup=[TestHelpers] begin
    pkg_path = joinpath(TestHelpers.TESTDATA_DIR, "BrokenEnvPackage")
    discovered = TestHelpers.discover_test_items(pkg_path)

    @test length(discovered.items) >= 1

    # Run with multiple processes — precompile process failure should prevent all from running
    result = TestHelpers.run_testrun(discovered; max_procs=3)

    errored_events = filter(e -> e.event == :errored, result.events)
    passed_events = filter(e -> e.event == :passed, result.events)

    @test length(errored_events) == length(discovered.items)
    @test length(passed_events) == 0

    for e in errored_events
        @test length(e.messages) >= 1
        msg = e.messages[1].message
        @test occursin("activation failed", msg) || occursin("activation failed", lowercase(msg))
    end
end
