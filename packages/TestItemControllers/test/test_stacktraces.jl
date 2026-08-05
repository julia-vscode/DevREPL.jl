@testitem "Erroring test item has stack trace" setup=[TestHelpers] begin
    pkg_path = joinpath(TestHelpers.TESTDATA_DIR, "BasicPackage")
    discovered = TestHelpers.discover_test_items(pkg_path)

    erroring_items = filter(i -> i.label == "erroring test", discovered.items)
    @test length(erroring_items) == 1

    result = TestHelpers.run_testrun(erroring_items, discovered.setups, discovered)

    errored_events = filter(e -> e.event == :errored, result.events)
    @test length(errored_events) == 1

    msg = errored_events[1].messages[1]
    @test occursin("intentional error", msg.message)

    # The error should have a stack trace
    @test msg.stack_trace !== nothing
    @test length(msg.stack_trace) >= 1

    # Each frame should have a label
    for frame in msg.stack_trace
        @test frame.label isa String
        @test !isempty(frame.label)
    end
end

@testitem "Deep stack erroring test has multiple frames" setup=[TestHelpers] begin
    pkg_path = joinpath(TestHelpers.TESTDATA_DIR, "BasicPackage")
    discovered = TestHelpers.discover_test_items(pkg_path)

    items = filter(i -> i.label == "erroring test deep stack", discovered.items)
    @test length(items) == 1

    result = TestHelpers.run_testrun(items, discovered.setups, discovered)

    errored_events = filter(e -> e.event == :errored, result.events)
    @test length(errored_events) == 1

    msg = errored_events[1].messages[1]
    @test occursin("deep error", msg.message)

    @test msg.stack_trace !== nothing
    # Should have frames for inner, middle, outer at minimum
    @test length(msg.stack_trace) >= 3

    labels = [f.label for f in msg.stack_trace]
    @test any(l -> occursin("inner", l), labels)
    @test any(l -> occursin("middle", l), labels)
    @test any(l -> occursin("outer", l), labels)
end

@testitem "Error via package function has stack trace with URI" setup=[TestHelpers] begin
    pkg_path = joinpath(TestHelpers.TESTDATA_DIR, "BasicPackage")
    discovered = TestHelpers.discover_test_items(pkg_path)

    items = filter(i -> i.label == "erroring test via package", discovered.items)
    @test length(items) == 1

    result = TestHelpers.run_testrun(items, discovered.setups, discovered)

    errored_events = filter(e -> e.event == :errored, result.events)
    @test length(errored_events) == 1

    msg = errored_events[1].messages[1]
    @test msg.stack_trace !== nothing

    # At least one frame should have a uri pointing to a file
    frames_with_uri = filter(f -> f.uri !== nothing, msg.stack_trace)
    @test length(frames_with_uri) >= 1

    # Frames with a URI should also have line and column info
    for frame in frames_with_uri
        @test frame.line !== nothing
        @test frame.line >= 1
        @test frame.column !== nothing
        @test frame.column >= 1
    end

    # The buggy_func frame should be present
    labels = [f.label for f in msg.stack_trace]
    @test any(l -> occursin("buggy_func", l), labels)
end

@testitem "Failing test item has no stack trace" setup=[TestHelpers] begin
    # @test failures (Test.Fail) don't produce backtraces, only Test.Error does
    pkg_path = joinpath(TestHelpers.TESTDATA_DIR, "BasicPackage")
    discovered = TestHelpers.discover_test_items(pkg_path)

    failing_items = filter(i -> i.label == "failing test", discovered.items)
    @test length(failing_items) == 1

    result = TestHelpers.run_testrun(failing_items, discovered.setups, discovered)

    failed_events = filter(e -> e.event == :failed, result.events)
    @test length(failed_events) == 1

    # Test.Fail objects don't have backtraces, so stack_trace should be nothing
    for msg in failed_events[1].messages
        @test msg.stack_trace === nothing
    end
end

@testitem "Multiple failing assertions each have messages" setup=[TestHelpers] begin
    pkg_path = joinpath(TestHelpers.TESTDATA_DIR, "BasicPackage")
    discovered = TestHelpers.discover_test_items(pkg_path)

    items = filter(i -> i.label == "failing test multiple", discovered.items)
    @test length(items) == 1

    result = TestHelpers.run_testrun(items, discovered.setups, discovered)

    failed_events = filter(e -> e.event == :failed, result.events)
    @test length(failed_events) == 1
    @test length(failed_events[1].messages) >= 2
end

@testitem "_convert_stack_trace with missing input" begin
    using TestItemControllers: TestItemControllers

    result = TestItemControllers._convert_stack_trace(missing)
    @test result === nothing
end

@testitem "_convert_stack_trace with frames" begin
    using TestItemControllers: TestItemControllers, TestItemServerProtocol
    using TestItemControllers: TestMessageStackFrame

    server_frames = [
        TestItemServerProtocol.TestMessageStackFrame(
            label = "my_func",
            uri = "file:///src/foo.jl",
            location = TestItemServerProtocol.Location(
                "file:///src/foo.jl",
                TestItemServerProtocol.Position(10, 3),
            ),
        ),
        TestItemServerProtocol.TestMessageStackFrame(
            label = "top-level scope",
            uri = missing,
            location = missing,
        ),
    ]

    result = TestItemControllers._convert_stack_trace(server_frames)
    @test result isa Vector{TestMessageStackFrame}
    @test length(result) == 2

    @test result[1].label == "my_func"
    @test result[1].uri == "file:///src/foo.jl"
    @test result[1].line == 10
    @test result[1].column == 3

    @test result[2].label == "top-level scope"
    @test result[2].uri === nothing
    @test result[2].line === nothing
    @test result[2].column === nothing
end

@testitem "TestMessage with missing stackTrace round-trip" begin
    using TestItemControllers: TestItemControllerProtocol, JSON

    msg = TestItemControllerProtocol.TestMessage(
        message = "Test failed",
        expectedOutput = "1",
        actualOutput = "2",
        uri = "file:///test.jl",
        line = 10,
        column = 5,
        stackTrace = missing,
    )

    json_str = JSON.json(msg)
    parsed = JSON.parse(json_str)
    msg2 = TestItemControllerProtocol.TestMessage(parsed)

    @test msg2.message == "Test failed"
    @test ismissing(msg2.stackTrace)
end

@testitem "TestMessage with empty stackTrace round-trip" begin
    using TestItemControllers: TestItemControllerProtocol, JSON

    msg = TestItemControllerProtocol.TestMessage(
        message = "Error",
        expectedOutput = missing,
        actualOutput = missing,
        uri = "file:///test.jl",
        line = 1,
        column = 1,
        stackTrace = TestItemControllerProtocol.TestMessageStackFrame[],
    )

    json_str = JSON.json(msg)
    parsed = JSON.parse(json_str)
    msg2 = TestItemControllerProtocol.TestMessage(parsed)

    @test !ismissing(msg2.stackTrace)
    @test isempty(msg2.stackTrace)
end

@testitem "Server TestMessage with stackTrace round-trip" begin
    using TestItemControllers: TestItemServerProtocol, JSON

    msg = TestItemServerProtocol.TestMessage(
        message = "Error occurred",
        expectedOutput = missing,
        actualOutput = missing,
        location = TestItemServerProtocol.Location(
            "file:///test.jl",
            TestItemServerProtocol.Position(5, 1),
        ),
        stackTrace = [
            TestItemServerProtocol.TestMessageStackFrame(
                label = "do_thing",
                uri = "file:///src/a.jl",
                location = TestItemServerProtocol.Location(
                    "file:///src/a.jl",
                    TestItemServerProtocol.Position(42, 1),
                ),
            ),
            TestItemServerProtocol.TestMessageStackFrame(
                label = "unknown",
                uri = missing,
                location = missing,
            ),
        ],
    )

    json_str = JSON.json(msg)
    parsed = JSON.parse(json_str)
    msg2 = TestItemServerProtocol.TestMessage(parsed)

    @test msg2.message == "Error occurred"
    @test !ismissing(msg2.stackTrace)
    @test length(msg2.stackTrace) == 2

    @test msg2.stackTrace[1].label == "do_thing"
    @test msg2.stackTrace[1].uri == "file:///src/a.jl"
    @test !ismissing(msg2.stackTrace[1].location)
    @test msg2.stackTrace[1].location.position.line == 42

    @test msg2.stackTrace[2].label == "unknown"
    @test ismissing(msg2.stackTrace[2].uri)
    @test ismissing(msg2.stackTrace[2].location)
end

@testitem "Server TestMessage without stackTrace round-trip" begin
    using TestItemControllers: TestItemServerProtocol, JSON

    msg = TestItemServerProtocol.TestMessage(
        "Just an error",
        TestItemServerProtocol.Location(
            "file:///test.jl",
            TestItemServerProtocol.Position(1, 1),
        ),
    )

    json_str = JSON.json(msg)
    parsed = JSON.parse(json_str)
    msg2 = TestItemServerProtocol.TestMessage(parsed)

    @test msg2.message == "Just an error"
    @test ismissing(msg2.stackTrace)
    @test ismissing(msg2.expectedOutput)
    @test ismissing(msg2.actualOutput)
end

@testitem "TestMessageStackFrame round-trip with all fields" begin
    using TestItemControllers: TestItemControllerProtocol, JSON

    frame = TestItemControllerProtocol.TestMessageStackFrame(
        label = "my_function",
        uri = "file:///src/module.jl",
        line = 99,
        column = 5,
    )

    json_str = JSON.json(frame)
    parsed = JSON.parse(json_str)
    frame2 = TestItemControllerProtocol.TestMessageStackFrame(parsed)

    @test frame2.label == "my_function"
    @test frame2.uri == "file:///src/module.jl"
    @test frame2.line == 99
    @test frame2.column == 5
end

@testitem "TestMessageStackFrame round-trip with missing fields" begin
    using TestItemControllers: TestItemControllerProtocol, JSON

    frame = TestItemControllerProtocol.TestMessageStackFrame(
        label = "anonymous",
        uri = missing,
        line = missing,
        column = missing,
    )

    json_str = JSON.json(frame)
    parsed = JSON.parse(json_str)
    frame2 = TestItemControllerProtocol.TestMessageStackFrame(parsed)

    @test frame2.label == "anonymous"
    @test ismissing(frame2.uri)
    @test ismissing(frame2.line)
    @test ismissing(frame2.column)
end

# ── Integration tests: @test wrapping exceptions ──

@testitem "Error inside @test produces failed event" setup=[TestHelpers] begin
    pkg_path = joinpath(TestHelpers.TESTDATA_DIR, "BasicPackage")
    discovered = TestHelpers.discover_test_items(pkg_path)

    items = filter(i -> i.label == "test error inside @test", discovered.items)
    @test length(items) == 1

    result = TestHelpers.run_testrun(items, discovered.setups, discovered)

    failed_events = filter(e -> e.event == :failed, result.events)
    @test length(failed_events) == 1
    @test length(failed_events[1].messages) >= 1

    msg = failed_events[1].messages[1]
    @test occursin("inside test macro", msg.message)

    # The message location should point to the @test line (i.source)
    @test msg.uri !== nothing
    @test msg.line !== nothing
end

@testitem "Deep error inside @test has multiple frames" setup=[TestHelpers] begin
    pkg_path = joinpath(TestHelpers.TESTDATA_DIR, "BasicPackage")
    discovered = TestHelpers.discover_test_items(pkg_path)

    items = filter(i -> i.label == "test error inside @test deep stack", discovered.items)
    @test length(items) == 1

    result = TestHelpers.run_testrun(items, discovered.setups, discovered)

    failed_events = filter(e -> e.event == :failed, result.events)
    @test length(failed_events) == 1

    msg = failed_events[1].messages[1]
    @test occursin("deep @test error", msg.message)

    @test msg.stack_trace !== nothing
    @test length(msg.stack_trace) >= 3

    labels = [f.label for f in msg.stack_trace]
    @test any(l -> occursin("inner_test_func", l), labels)
    @test any(l -> occursin("middle_test_func", l), labels)
    @test any(l -> occursin("outer_test_func", l), labels)

    # At least some frames should have file URIs
    frames_with_uri = filter(f -> f.uri !== nothing, msg.stack_trace)
    @test length(frames_with_uri) >= 1
end
