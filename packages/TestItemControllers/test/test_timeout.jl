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
    result = TestHelpers.run_testrun(all_items, discovered.setups, discovered; timeout=600, item_timeouts=Dict(slow.id => 5.0))

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

@testitem "Timeout warning carries the evidence for which channel failed" setup=[TestHelpers] begin
    using TestItemControllers: TestProcessState, ProcessEnv, _timeout_evidence

    # A timeout only ever proves that the *result* never arrived. A test process talks to
    # the controller over two independent channels — the JSON-RPC socket carrying results
    # and the stdout/stderr pipes carrying output — and which of them went quiet is what
    # separates "the test hung" from "the connection died". These are the numbers that make
    # that visible in the log instead of only in a post-mortem of the run's artifacts.
    env = ProcessEnv(nothing, "file:///tmp/BasicPackage", "BasicPackage", "julia", String[], nothing, "Normal", Dict{String,Union{String,Nothing}}())
    ps = TestProcessState("proc-1", env)

    # Nothing heard on either channel yet: reported as unknown rather than as zero.
    evidence = _timeout_evidence(ps, nothing)
    @test evidence.seconds_since_last_message === nothing
    @test evidence.seconds_since_last_output === nothing
    @test evidence.watchdog_dump == false

    # The shape that says the connection died and the test did not: the socket has been
    # quiet for an hour while output arrived seconds ago, and the process's own hang
    # watchdog left no dump.
    now = time()
    ps.last_message_at = now - 3600
    ps.last_output_at = now - 5
    evidence = _timeout_evidence(ps, nothing)
    @test evidence.seconds_since_last_message >= 3600
    @test evidence.seconds_since_last_output < 60
    @test evidence.watchdog_dump == false

    # A genuine hang looks the opposite way round: the watchdog dumped at the deadline.
    @test _timeout_evidence(ps, "backtrace goes here").watchdog_dump == true

    # No endpoint, so the outbound backlog is unknown — never a bogus zero.
    @test evidence.outbound_queued === nothing
    @test evidence.outbound_blocked_seconds === nothing

    # And the whole thing has to splat into the log call the way the handler uses it.
    @test_logs (:warn,) (@warn "x" _timeout_evidence(ps, nothing)...)
end
