@testitem "New processes in second run skip precompile wait" setup=[TestHelpers] begin
    # Regression test: when a second test run creates new processes for an
    # environment that was already precompiled in run 1, those new processes
    # must not get stuck waiting in ProcessWaitingForPrecompile.
    #
    # The bug: new processes were initialized with precompile_done=false and
    # is_precompile_process=false.  Since the env was already in
    # precompiled_envs no PrecompileDoneMsg was ever emitted, so the new
    # processes waited forever.

    using TestItemControllers: TestItemController, TestRunItem, execute_testrun, shutdown,
        CancellationTokens, ControllerCallbacks
    import UUIDs

    pkg_path = joinpath(TestHelpers.TESTDATA_DIR, "BasicPackage")
    discovered = TestHelpers.discover_test_items(pkg_path)

    passing_items = filter(i -> i.label in ("add works", "greet works"), discovered.items)
    @test length(passing_items) == 2

    # -- bookkeeping ----------------------------------------------------------
    process_created_ids = String[]
    pc_lock = ReentrantLock()

    events = NamedTuple[]
    events_lock = ReentrantLock()

    callbacks = ControllerCallbacks(
        on_testitem_started = (run_id, item_id, test_env_id) -> nothing,
        on_testitem_passed = (run_id, item_id, test_env_id, duration) -> lock(events_lock) do
            push!(events, (event=:passed, run_id=run_id, item_id=item_id))
        end,
        on_testitem_failed = (run_id, item_id, test_env_id, messages, duration) -> lock(events_lock) do
            push!(events, (event=:failed, run_id=run_id, item_id=item_id))
        end,
        on_testitem_errored = (run_id, item_id, test_env_id, messages, duration) -> lock(events_lock) do
            push!(events, (event=:errored, run_id=run_id, item_id=item_id))
        end,
        on_testitem_skipped = (run_id, item_id, test_env_id) -> nothing,
        on_append_output = (run_id, item_id, test_env_id, output) -> nothing,
        on_attach_debugger = (run_id, pipe_name) -> nothing,
        on_process_created = (id, test_env_id) -> lock(pc_lock) do
            push!(process_created_ids, id)
        end,
    )

    controller = TestItemController(callbacks; log_level=:Debug)

    controller_task = @async try
        run(controller)
    catch err
        @error "Controller error" exception=(err, catch_backtrace())
    end

    # -- Run 1: single item, single process (triggers precompilation) ---------
    run1_id = string(UUIDs.uuid4())
    test_env = TestHelpers.make_test_environment(; TestHelpers._env_kwargs(discovered)...)

    work_units1 = [TestRunItem(item.id, test_env.id, nothing, :Debug) for item in passing_items[1:1]]
    execute_testrun(
        controller,
        run1_id,
        [test_env],
        passing_items[1:1],   # only one item
        work_units1,
        discovered.setups,
        1,
        nothing
    )

    run1_passed = lock(events_lock) do
        filter(e -> e.event == :passed && e.run_id == run1_id, events)
    end
    @test length(run1_passed) == 1

    procs_after_run1 = lock(pc_lock) do; length(process_created_ids); end
    @test procs_after_run1 == 1        # exactly one process created

    # -- Run 2: two items, two processes (must NOT hang) ----------------------
    # Use a cancellation token so we can abort if the bug causes a hang.
    run2_id = string(UUIDs.uuid4())
    run2_cs = CancellationTokens.CancellationTokenSource()
    run2_token = CancellationTokens.get_token(run2_cs)

    run2_task = @async try
        work_units2 = [TestRunItem(item.id, test_env.id, nothing, :Debug) for item in passing_items]
        execute_testrun(
            controller,
            run2_id,
            [test_env],
            passing_items,         # two items → needs two processes
            work_units2,
            discovered.setups,
            2,
            run2_token
        )
    catch err
        if !isa(err, ErrorException) || !contains(err.msg, "timed out")
            @error "Run 2 error" exception=(err, catch_backtrace())
        end
    end

    # Wait with a timeout — without the fix the new process is stuck in
    # ProcessWaitingForPrecompile and this would hang forever.
    TestHelpers.timed_wait(run2_task, 120; label="second-run-execute_testrun")

    run2_passed = lock(events_lock) do
        filter(e -> e.event == :passed && e.run_id == run2_id, events)
    end
    # Both test items must have passed.
    @test length(run2_passed) == 2

    # A second process should have been created for run 2
    procs_after_run2 = lock(pc_lock) do; length(process_created_ids); end
    @test procs_after_run2 == 2

    # -- cleanup --------------------------------------------------------------
    shutdown(controller)
    TestHelpers.timed_wait(controller_task, 120; label="second-run-multiproc-controller")
end
