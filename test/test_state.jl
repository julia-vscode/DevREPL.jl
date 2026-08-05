@testitem "TestProcessState construction defaults" begin
    using TestItemControllers: TestProcessState, ProcessEnv, state, ProcessCreated, CancellationTokens

    env = ProcessEnv(
        "file:///project",
        "file:///package",
        "MyPkg",
        "julia",
        String[],
        nothing,
        "Run",
        Dict{String,Union{String,Nothing}}()
    )

    ps = TestProcessState("proc-1", env)

    @test ps.id == "proc-1"
    @test state(ps.fsm) == ProcessCreated
    @test ps.env === env
    @test ps.testrun_id === nothing
    @test ps.jl_process === nothing
    @test ps.endpoint === nothing
    @test ps.current_testitem_id === nothing
    @test ps.current_testitem_started_at === nothing
    @test ps.timeout_cs === nothing
    @test ps.timeout_reg === nothing
    @test ps.termination_reg === nothing
    @test isempty(ps.process_tasks)
    @test ps.is_precompile_process == false
    @test ps.precompile_done == false
    @test ps.test_env_content_hash === nothing
    @test ps.testrun_token === nothing
    @test ps.testrun_watcher_registration === nothing
    @test ps.test_setups === nothing
    @test ps.coverage_root_uris === nothing
    @test ps.proc_log_level == :Info
    # debug_pipe_name should be a non-empty string
    @test !isempty(ps.debug_pipe_name)
    # cs should be a valid CancellationTokenSource
    @test !CancellationTokens.is_cancellation_requested(CancellationTokens.get_token(ps.cs))
end

@testitem "TestProcessState precompile options" begin
    using TestItemControllers: TestProcessState, ProcessEnv, state, ProcessCreated

    env = ProcessEnv(
        nothing,
        "file:///package",
        "MyPkg",
        "julia",
        String[],
        nothing,
        "Run",
        Dict{String,Union{String,Nothing}}()
    )

    # With precompile options
    ps = TestProcessState("proc-2", env;
        is_precompile_process=true,
        precompile_done=true,
        test_env_content_hash="abc123"
    )

    @test ps.is_precompile_process == true
    @test ps.precompile_done == true
    @test ps.test_env_content_hash == "abc123"
    @test state(ps.fsm) == ProcessCreated
end

@testitem "TestRunState construction" begin
    using TestItemControllers: TestRunState, TestEnvironment, TestRunItem, TestItemDetail, TestSetupDetail,
        state, TestRunCreated, CancellationTokens

    test_env = TestEnvironment(
        "env-1", "julia", String[], nothing,
        Dict{String,Union{String,Nothing}}(), "Run",
        "Pkg", "file:///pkg", "file:///proj", nothing
    )

    items = [
        TestItemDetail("item-1", "file:///test.jl", "test1",
            "Pkg", "file:///pkg", true, String[], 1, 1, "@test true", 1, 1),
        TestItemDetail("item-2", "file:///test.jl", "test2",
            "Pkg", "file:///pkg", true, String[], 5, 1, "@test false", 5, 1),
    ]

    work_units = [
        TestRunItem("item-1", "env-1", nothing, :Info),
        TestRunItem("item-2", "env-1", nothing, :Info),
    ]

    setups = TestSetupDetail[]

    rs = TestRunState("run-1", [test_env], items, work_units, setups, 1)

    @test rs.id == "run-1"
    @test state(rs.fsm) == TestRunCreated
    @test length(rs.test_environments) == 1
    @test length(rs.remaining_work) == 2
    @test haskey(rs.remaining_work, ("item-1", "env-1"))
    @test haskey(rs.remaining_work, ("item-2", "env-1"))
    @test rs.test_items["item-1"].label == "test1"
    @test isempty(rs.test_setups)
    @test rs.procs === nothing
    @test isempty(rs.testitem_ids_by_proc)
    @test isempty(rs.stolen_ids_by_proc)
    @test isempty(rs.items_dispatched_to_procs)
    @test isempty(rs.processes_ready_before_acquired)
    @test isempty(rs.coverage)
    # completion_channel should be open
    @test isopen(rs.completion_channel)
end

@testitem "TestRunState with cancellation token" begin
    using TestItemControllers: TestRunState, TestEnvironment, TestRunItem, TestItemDetail, TestSetupDetail,
        CancellationTokens

    test_env = TestEnvironment(
        "env-1", "julia", String[], nothing,
        Dict{String,Union{String,Nothing}}(), "Run",
        "Pkg", "file:///pkg", "file:///proj", nothing
    )

    items = [
        TestItemDetail("item-1", "file:///test.jl", "test1",
            "Pkg", "file:///pkg", true, String[], 1, 1, "@test true", 1, 1),
    ]

    work_units = [TestRunItem("item-1", "env-1", nothing, :Info)]

    parent_cs = CancellationTokens.CancellationTokenSource()
    parent_token = CancellationTokens.get_token(parent_cs)

    rs = TestRunState("run-linked", [test_env], items, work_units, TestSetupDetail[], 1; token=parent_token)

    # Cancelling the parent should propagate to the run's cancellation source
    @test !CancellationTokens.is_cancellation_requested(CancellationTokens.get_token(rs.cancellation_source))
    CancellationTokens.cancel(parent_cs)
    @test CancellationTokens.is_cancellation_requested(CancellationTokens.get_token(rs.cancellation_source))
end

@testitem "TestRunState without cancellation token" begin
    using TestItemControllers: TestRunState, TestEnvironment, TestRunItem, TestItemDetail, TestSetupDetail,
        CancellationTokens

    test_env = TestEnvironment(
        "env-1", "julia", String[], nothing,
        Dict{String,Union{String,Nothing}}(), "Run",
        "", "", nothing, nothing
    )

    rs = TestRunState("run-no-token", [test_env], TestItemDetail[], TestRunItem[], TestSetupDetail[], 1)

    # Should have its own independent cancellation source
    @test !CancellationTokens.is_cancellation_requested(CancellationTokens.get_token(rs.cancellation_source))
end
