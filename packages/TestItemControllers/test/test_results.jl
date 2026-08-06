@testitem "Results JSON round-trip" begin
    using TestItemControllers.Results

    result = TestrunResult(
        [TestrunResultDefinitionError("Invalid testitem", "file:///c%3A/foo/test/bad.jl", 3, 1)],
        [
            TestrunResultTestitem(
                "passing item",
                "file:///c%3A/foo/test/a.jl",
                [TestrunResultTestitemProfile("Julia 1.12.0~x64:ubuntu-latest", :passed, 12.5, nothing, nothing)],
            ),
            TestrunResultTestitem(
                "failing item",
                "file:///c%3A/foo/test/b.jl",
                [
                    TestrunResultTestitemProfile(
                        "Julia 1.12.0~x64:ubuntu-latest",
                        :failed,
                        873.0,
                        [TestrunResultMessage(
                            "Test Failed at b.jl:5",
                            "1",
                            "2",
                            "file:///c%3A/foo/test/b.jl",
                            5,
                            9,
                            [TestrunResultStackFrame("f", "file:///c%3A/foo/src/f.jl", 10, 1)],
                        )],
                        "some captured output",
                    ),
                    TestrunResultTestitemProfile("Julia 1.12.0~x64:windows-latest", :crash, nothing, nothing, nothing),
                ],
            ),
        ],
        Dict("process-1" => "process output here"),
    )

    io = IOBuffer()
    write_json(io, result)
    roundtripped = read_json(IOBuffer(String(take!(io))))

    @test roundtripped isa TestrunResult
    @test length(roundtripped.definition_errors) == 1
    @test roundtripped.definition_errors[1].message == "Invalid testitem"
    @test roundtripped.definition_errors[1].line == 3
    @test length(roundtripped.testitems) == 2

    ti1 = roundtripped.testitems[1]
    @test ti1.name == "passing item"
    @test ti1.uri == "file:///c%3A/foo/test/a.jl"
    @test length(ti1.profiles) == 1
    @test ti1.profiles[1].status == :passed
    @test ti1.profiles[1].duration == 12.5
    @test ti1.profiles[1].messages === nothing
    @test ti1.profiles[1].output === nothing

    ti2 = roundtripped.testitems[2]
    @test length(ti2.profiles) == 2
    p1 = ti2.profiles[1]
    @test p1.status == :failed
    @test p1.output == "some captured output"
    @test length(p1.messages) == 1
    msg = p1.messages[1]
    @test msg.message == "Test Failed at b.jl:5"
    @test msg.expected_output == "1"
    @test msg.actual_output == "2"
    @test msg.line == 5
    @test length(msg.stack_frames) == 1
    @test msg.stack_frames[1].label == "f"
    @test msg.stack_frames[1].line == 10
    p2 = ti2.profiles[2]
    @test p2.status == :crash
    @test p2.duration === nothing

    @test roundtripped.process_outputs == Dict("process-1" => "process output here")
end

@testitem "Results JSON file round-trip" begin
    using TestItemControllers.Results

    result = TestrunResult(
        TestrunResultDefinitionError[],
        [TestrunResultTestitem("item", "file:///tmp/a.jl",
            [TestrunResultTestitemProfile("Default", :passed, 1.0, nothing, nothing)])],
        Dict{String,String}(),
    )

    mktempdir() do dir
        path = joinpath(dir, "results.json")
        write_json(path, result)
        roundtripped = read_json(path)
        @test roundtripped.testitems[1].name == "item"
        @test roundtripped.testitems[1].profiles[1].status == :passed
    end
end

@testitem "Results names re-exported from TestItemControllers" begin
    using TestItemControllers

    @test TestrunResult === TestItemControllers.Results.TestrunResult
    @test TestrunResultTestitem === TestItemControllers.Results.TestrunResultTestitem
end
