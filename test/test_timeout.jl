@testitem "Test item timeout" setup=[TestHelpers] begin
    using TestItemControllers: TestItemDetail

    pkg_path = joinpath(TestHelpers.TESTDATA_DIR, "BasicPackage")
    discovered = TestHelpers.discover_test_items(pkg_path)

    # Get the slow test item
    slow_items = filter(i -> i.label == "slow test", discovered.items)
    @test length(slow_items) == 1
    slow = slow_items[1]

    # Also include a passing item to verify it still completes
    passing_items = filter(i -> i.label == "add works", discovered.items)
    @test length(passing_items) == 1

    all_items = [slow; passing_items]

    # Set a 5-second timeout on the slow item via work unit timeouts
    result = TestHelpers.run_testrun(all_items, discovered.setups, discovered; timeout=120, item_timeouts=Dict(slow.id => 5.0))

    # The timed-out item should be errored
    errored = filter(e -> e.event == :errored, result.events)
    @test length(errored) >= 1

    timed_errored = filter(e -> e.testitem_id == slow.id, errored)
    @test length(timed_errored) == 1

    # Error message should mention timeout
    msgs = timed_errored[1].messages
    @test length(msgs) >= 1
    msg_text = msgs[1].message
    @test occursin("timeout", lowercase(msg_text)) || occursin("timed out", lowercase(msg_text))

    # The passing item should still pass
    passed = filter(e -> e.event == :passed, result.events)
    @test length(passed) >= 1
end
