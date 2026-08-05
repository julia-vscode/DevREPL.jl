@testitem "TestMessage round-trip" begin
    using TestItemControllers: TestItemControllerProtocol, JSON

    msg = TestItemControllerProtocol.TestMessage(
        message = "Test failed",
        expectedOutput = "1",
        actualOutput = "2",
        uri = "file:///test.jl",
        line = 10,
        column = 5
    )

    json_str = JSON.json(msg)
    parsed = JSON.parse(json_str)
    msg2 = TestItemControllerProtocol.TestMessage(parsed)

    @test msg2.message == "Test failed"
    @test msg2.expectedOutput == "1"
    @test msg2.actualOutput == "2"
    @test msg2.uri == "file:///test.jl"
    @test msg2.line == 10
    @test msg2.column == 5
end

@testitem "TestMessage with missing fields" begin
    using TestItemControllers: TestItemControllerProtocol, JSON

    msg = TestItemControllerProtocol.TestMessage(
        message = "Error occurred",
        expectedOutput = missing,
        actualOutput = missing,
        uri = missing,
        line = missing,
        column = missing
    )

    json_str = JSON.json(msg)
    parsed = JSON.parse(json_str)
    msg2 = TestItemControllerProtocol.TestMessage(parsed)

    @test msg2.message == "Error occurred"
    @test ismissing(msg2.expectedOutput)
    @test ismissing(msg2.actualOutput)
end

@testitem "TestMessage with stackTrace round-trip" begin
    using TestItemControllers: TestItemControllerProtocol, JSON

    msg = TestItemControllerProtocol.TestMessage(
        message = "Some error",
        uri = "file:///test.jl",
        line = 5,
        column = 1,
        stackTrace = [
            TestItemControllerProtocol.TestMessageStackFrame(
                label = "my_function",
                uri = "file:///src/foo.jl",
                line = 42,
                column = 1,
            ),
            TestItemControllerProtocol.TestMessageStackFrame(
                label = "top-level scope",
                uri = missing,
                line = missing,
                column = missing,
            ),
        ],
    )

    json_str = JSON.json(msg)
    parsed = JSON.parse(json_str)
    msg2 = TestItemControllerProtocol.TestMessage(parsed)

    @test msg2.message == "Some error"
    @test !ismissing(msg2.stackTrace)
    @test length(msg2.stackTrace) == 2

    @test msg2.stackTrace[1].label == "my_function"
    @test msg2.stackTrace[1].uri == "file:///src/foo.jl"
    @test msg2.stackTrace[1].line == 42
    @test msg2.stackTrace[1].column == 1

    @test msg2.stackTrace[2].label == "top-level scope"
    @test ismissing(msg2.stackTrace[2].uri)
    @test ismissing(msg2.stackTrace[2].line)
end

@testitem "TestItemDetail round-trip" begin
    using TestItemControllers: TestItemControllerProtocol, JSON

    item = TestItemControllerProtocol.TestItemDetail(
        id = "item-1",
        uri = "file:///test.jl",
        label = "my test",
        packageName = "MyPkg",
        packageUri = "file:///mypkg",
        useDefaultUsings = true,
        testSetups = ["Setup1"],
        line = 1,
        column = 1,
        code = "@test true",
        codeLine = 2,
        codeColumn = 5
    )

    json_str = JSON.json(item)
    parsed = JSON.parse(json_str)
    item2 = TestItemControllerProtocol.TestItemDetail(parsed)

    @test item2.id == "item-1"
    @test item2.label == "my test"
    @test item2.packageName == "MyPkg"
    @test item2.packageUri == "file:///mypkg"
    @test item2.useDefaultUsings == true
    @test item2.testSetups == ["Setup1"]
    @test item2.code == "@test true"
end

@testitem "FileCoverage round-trip" begin
    using TestItemControllers: TestItemControllerProtocol, JSON

    fc = TestItemControllerProtocol.FileCoverage(
        uri = "file:///src/myfile.jl",
        coverage = [1, 0, nothing, 3, nothing]
    )

    json_str = JSON.json(fc)
    parsed = JSON.parse(json_str)
    fc2 = TestItemControllerProtocol.FileCoverage(parsed)

    @test fc2.uri == "file:///src/myfile.jl"
    @test fc2.coverage == [1, 0, nothing, 3, nothing]
end

@testitem "CreateTestRunParams round-trip" begin
    using TestItemControllers: TestItemControllerProtocol, JSON

    params = TestItemControllerProtocol.CreateTestRunParams(
        testRunId = "run-1",
        testEnvironments = [
            TestItemControllerProtocol.TestEnvironment(
                id = "env-1",
                juliaCmd = "julia",
                juliaArgs = String[],
                juliaNumThreads = missing,
                juliaEnv = Dict{String,Union{String,Nothing}}(),
                mode = "Run",
                packageName = "MyPkg",
                packageUri = "file:///mypkg",
                projectUri = missing,
                envContentHash = missing,
            )
        ],
        testItems = TestItemControllerProtocol.TestItemDetail[],
        workUnits = TestItemControllerProtocol.TestRunItem[],
        testSetups = TestItemControllerProtocol.TestSetupDetail[],
        maxProcessCount = 1,
        coverageRootUris = missing,
    )

    json_str = JSON.json(params)
    parsed = JSON.parse(json_str)
    params2 = TestItemControllerProtocol.CreateTestRunParams(parsed)

    @test params2.testRunId == "run-1"
    @test length(params2.testEnvironments) == 1
    @test params2.testEnvironments[1].mode == "Run"
    @test params2.maxProcessCount == 1
    @test ismissing(params2.coverageRootUris)
end

@testitem "TestEnvironment round-trip with all fields" begin
    using TestItemControllers: TestItemControllerProtocol, JSON

    env = TestItemControllerProtocol.TestEnvironment(
        id = "env-full",
        juliaCmd = "/usr/bin/julia",
        juliaArgs = ["--optimize=2", "--check-bounds=yes"],
        juliaNumThreads = "4",
        juliaEnv = Dict{String,Union{String,Nothing}}("MY_VAR" => "value", "EMPTY" => nothing),
        mode = "Coverage",
        packageName = "MyPkg",
        packageUri = "file:///mypkg",
        projectUri = "file:///proj",
        envContentHash = "abc123",
    )

    json_str = JSON.json(env)
    parsed = JSON.parse(json_str)
    env2 = TestItemControllerProtocol.TestEnvironment(parsed)

    @test env2.id == "env-full"
    @test env2.juliaCmd == "/usr/bin/julia"
    @test env2.juliaArgs == ["--optimize=2", "--check-bounds=yes"]
    @test env2.juliaNumThreads == "4"
    @test env2.juliaEnv["MY_VAR"] == "value"
    @test env2.juliaEnv["EMPTY"] === nothing
    @test env2.mode == "Coverage"
    @test env2.packageName == "MyPkg"
    @test env2.packageUri == "file:///mypkg"
    @test env2.projectUri == "file:///proj"
    @test env2.envContentHash == "abc123"
end

@testitem "TestEnvironment round-trip with missing optional fields" begin
    using TestItemControllers: TestItemControllerProtocol, JSON

    env = TestItemControllerProtocol.TestEnvironment(
        id = "env-minimal",
        juliaCmd = "julia",
        juliaArgs = String[],
        juliaNumThreads = missing,
        juliaEnv = Dict{String,Union{String,Nothing}}(),
        mode = "Run",
        packageName = "MyPkg",
        packageUri = "file:///mypkg",
        projectUri = missing,
        envContentHash = missing,
    )

    json_str = JSON.json(env)
    parsed = JSON.parse(json_str)
    env2 = TestItemControllerProtocol.TestEnvironment(parsed)

    @test env2.id == "env-minimal"
    @test ismissing(env2.juliaNumThreads)
    @test ismissing(env2.projectUri)
    @test ismissing(env2.envContentHash)
    @test env2.juliaArgs == String[]
    @test isempty(env2.juliaEnv)
end

@testitem "TestMessage with all optional fields populated" begin
    using TestItemControllers: TestItemControllerProtocol, JSON

    msg = TestItemControllerProtocol.TestMessage(
        message = "Expected 42, got 43",
        expectedOutput = "42",
        actualOutput = "43",
        uri = "file:///test/mytest.jl",
        line = 25,
        column = 10
    )

    json_str = JSON.json(msg)
    parsed = JSON.parse(json_str)
    msg2 = TestItemControllerProtocol.TestMessage(parsed)

    @test msg2.message == "Expected 42, got 43"
    @test msg2.expectedOutput == "42"
    @test msg2.actualOutput == "43"
    @test msg2.uri == "file:///test/mytest.jl"
    @test msg2.line == 25
    @test msg2.column == 10
end

@testitem "CreateTestRunParams with multiple environments" begin
    using TestItemControllers: TestItemControllerProtocol, JSON

    params = TestItemControllerProtocol.CreateTestRunParams(
        testRunId = "run-multi",
        testEnvironments = [
            TestItemControllerProtocol.TestEnvironment(
                id = "env-1",
                juliaCmd = "julia", juliaArgs = String[],
                juliaNumThreads = missing,
                juliaEnv = Dict{String,Union{String,Nothing}}(),
                mode = "Run",
                packageName = "PkgA", packageUri = "file:///pkga",
                projectUri = missing, envContentHash = missing,
            ),
            TestItemControllerProtocol.TestEnvironment(
                id = "env-2",
                juliaCmd = "julia", juliaArgs = ["--code-coverage=user"],
                juliaNumThreads = "auto",
                juliaEnv = Dict{String,Union{String,Nothing}}("COV" => "1"),
                mode = "Coverage",
                packageName = "PkgB", packageUri = "file:///pkgb",
                projectUri = "file:///proj", envContentHash = "hash456",
            ),
        ],
        testItems = TestItemControllerProtocol.TestItemDetail[],
        workUnits = TestItemControllerProtocol.TestRunItem[],
        testSetups = TestItemControllerProtocol.TestSetupDetail[],
        maxProcessCount = 2,
        coverageRootUris = ["file:///src"],
    )

    json_str = JSON.json(params)
    parsed = JSON.parse(json_str)
    params2 = TestItemControllerProtocol.CreateTestRunParams(parsed)

    @test params2.testRunId == "run-multi"
    @test length(params2.testEnvironments) == 2
    @test params2.testEnvironments[1].id == "env-1"
    @test params2.testEnvironments[1].mode == "Run"
    @test params2.testEnvironments[2].id == "env-2"
    @test params2.testEnvironments[2].mode == "Coverage"
    @test params2.testEnvironments[2].juliaNumThreads == "auto"
    @test params2.testEnvironments[2].juliaArgs == ["--code-coverage=user"]
    @test params2.maxProcessCount == 2
    @test params2.coverageRootUris == ["file:///src"]
end

@testitem "TestRunItem round-trip with timeout" begin
    using TestItemControllers: TestItemControllerProtocol, JSON

    item = TestItemControllerProtocol.TestRunItem(
        testitemId = "item-timeout",
        testEnvId = "env-1",
        timeout = 30.0,
        logLevel = "Debug",
    )

    json_str = JSON.json(item)
    parsed = JSON.parse(json_str)
    item2 = TestItemControllerProtocol.TestRunItem(parsed)

    @test item2.testitemId == "item-timeout"
    @test item2.testEnvId == "env-1"
    @test item2.timeout == 30.0
    @test item2.logLevel == "Debug"
end

@testitem "TestRunItem round-trip with missing timeout" begin
    using TestItemControllers: TestItemControllerProtocol, JSON

    item = TestItemControllerProtocol.TestRunItem(
        testitemId = "item-no-timeout",
        testEnvId = "env-1",
        timeout = missing,
        logLevel = "Info",
    )

    json_str = JSON.json(item)
    parsed = JSON.parse(json_str)
    item2 = TestItemControllerProtocol.TestRunItem(parsed)

    @test item2.testitemId == "item-no-timeout"
    @test item2.testEnvId == "env-1"
    @test ismissing(item2.timeout)
    @test item2.logLevel == "Info"
end
