@testitem "Run failing test item" setup=[TestHelpers] begin
    pkg_path = joinpath(TestHelpers.TESTDATA_DIR, "BasicPackage")
    discovered = TestHelpers.discover_test_items(pkg_path)

    failing_items = filter(i -> i.label == "failing test", discovered.items)
    @test length(failing_items) == 1

    result = TestHelpers.run_testrun(failing_items, discovered.setups, discovered)

    failed_events = filter(e -> e.event == :failed, result.events)
    @test length(failed_events) == 1
    @test length(failed_events[1].messages) >= 1
end

@testitem "Run erroring test item" setup=[TestHelpers] begin
    pkg_path = joinpath(TestHelpers.TESTDATA_DIR, "BasicPackage")
    discovered = TestHelpers.discover_test_items(pkg_path)

    erroring_items = filter(i -> i.label == "erroring test", discovered.items)
    @test length(erroring_items) == 1

    result = TestHelpers.run_testrun(erroring_items, discovered.setups, discovered)

    started_events = filter(e -> e.event == :started, result.events)
    errored_events = filter(e -> e.event == :errored, result.events)
    failed_events = filter(e -> e.event == :failed, result.events)
    passed_events = filter(e -> e.event == :passed, result.events)

    # A thrown non-@test exception must produce exactly one :errored event, never :failed or :passed.
    @test length(started_events) == 1
    @test length(errored_events) == 1
    @test length(failed_events) == 0
    @test length(passed_events) == 0
    @test length(errored_events[1].messages) >= 1

    # The error message should mention "intentional error"
    msg_text = errored_events[1].messages[1].message
    @test occursin("intentional error", msg_text)

    # A non-@test throw should carry a stack trace pointing to user code.
    @test errored_events[1].messages[1].stack_trace !== nothing
    @test length(errored_events[1].messages[1].stack_trace) >= 1
end
