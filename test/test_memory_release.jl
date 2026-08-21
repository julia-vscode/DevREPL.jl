@testitem "Test item globals are released when the item finishes" setup=[TestHelpers] begin
    # A test item runs in a module of its own, and Julia cannot unload a module: without
    # the teardown in `release_module_globals!` everything the item bound to a global stays
    # reachable for the life of the test process, which is what
    # julia-testitems/TestItemRunner.jl#65 reports.
    #
    # The fixture's first item parks a `WeakRef` to a large array in `Main` — `Main` is not
    # a test code module, so the teardown leaves the probe itself alone — and its second
    # item collects and looks at what the reference still points at. They have to run in
    # this order on the same process, so they are driven as two consecutive runs rather
    # than as one run of two items.
    using TestItemControllers: TestItemController, TestRunItem, execute_testrun, shutdown, ControllerCallbacks
    import UUIDs

    pkg_path = joinpath(TestHelpers.TESTDATA_DIR, "MemoryPackage")
    discovered = TestHelpers.discover_test_items(pkg_path)

    bind_items = filter(i -> i.label == "memory probe: bind", discovered.items)
    check_items = filter(i -> i.label == "memory probe: check", discovered.items)
    @test length(bind_items) == 1
    @test length(check_items) == 1

    process_created_ids = String[]
    pc_lock = ReentrantLock()

    results = NamedTuple[]
    results_lock = ReentrantLock()

    callbacks = ControllerCallbacks(
        on_testitem_started = (run_id, item_id, test_env_id) -> nothing,
        on_testitem_passed = (run_id, item_id, test_env_id, duration) -> lock(results_lock) do
            push!(results, (event=:passed, testitem_id=item_id))
        end,
        on_testitem_failed = (run_id, item_id, test_env_id, messages, duration) -> lock(results_lock) do
            push!(results, (event=:failed, testitem_id=item_id, messages=messages))
        end,
        on_testitem_errored = (run_id, item_id, test_env_id, messages, duration) -> lock(results_lock) do
            push!(results, (event=:errored, testitem_id=item_id, messages=messages))
        end,
        on_testitem_skipped = (run_id, item_id, test_env_id) -> nothing,
        on_append_output = (run_id, item_id, test_env_id, output) -> nothing,
        on_attach_debugger = (run_id, pipe_name) -> nothing,
        on_process_created = (id, test_env_id) -> lock(pc_lock) do
            push!(process_created_ids, id)
        end,
    )

    controller = TestItemController(callbacks)
    test_env = TestHelpers.make_test_environment(; TestHelpers._env_kwargs(discovered)...)

    controller_task = @async try
        run(controller)
    catch err
        @error "Controller error" exception=(err, catch_backtrace())
    end

    try
        for items in (bind_items, check_items)
            execute_testrun(
                controller,
                string(UUIDs.uuid4()),
                [test_env],
                items,
                [TestRunItem(i.id, test_env.id, nothing, :Info) for i in items],
                discovered.setups,
                1,
                nothing
            )
        end
    finally
        shutdown(controller)
        TestHelpers.timed_wait(controller_task, 600; label="memory-release-controller")
    end

    # Both items must have run on the same process, or the probe proves nothing
    @test lock(pc_lock) do; length(process_created_ids) end == 1

    events = lock(results_lock) do; copy(results) end
    @test length(events) == 2
    # The second item is the assertion: it fails if the array the first item bound is still
    # reachable after a full collection
    @test all(e -> e.event == :passed, events)
end
