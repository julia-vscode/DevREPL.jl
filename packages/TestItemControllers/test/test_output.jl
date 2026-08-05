@testitem "Output capture from test items" setup=[TestHelpers] begin
    using TestItemControllers: TestItemController, TestRunItem, execute_testrun, shutdown, ControllerCallbacks
    import UUIDs
    @info "[test] Output capture from test items: starting"

    pkg_path = joinpath(TestHelpers.TESTDATA_DIR, "BasicPackage")
    discovered = TestHelpers.discover_test_items(pkg_path)

    # Select only the output-producing test item
    output_items = filter(i -> i.label == "output test", discovered.items)
    @test length(output_items) == 1

    outputs = NamedTuple[]
    outputs_lock = ReentrantLock()
    process_outputs = NamedTuple[]
    process_outputs_lock = ReentrantLock()

    events = NamedTuple[]
    events_lock = ReentrantLock()

    callbacks = ControllerCallbacks(
        on_testitem_started = (run_id, item_id, test_env_id) -> lock(events_lock) do
            push!(events, (event=:started, testitem_id=item_id))
        end,
        on_testitem_passed = (run_id, item_id, test_env_id, duration) -> lock(events_lock) do
            push!(events, (event=:passed, testitem_id=item_id))
        end,
        on_testitem_failed = (run_id, item_id, test_env_id, messages, duration) -> lock(events_lock) do
            push!(events, (event=:failed, testitem_id=item_id))
        end,
        on_testitem_errored = (run_id, item_id, test_env_id, messages, duration) -> lock(events_lock) do
            push!(events, (event=:errored, testitem_id=item_id))
        end,
        on_testitem_skipped = (run_id, item_id, test_env_id) -> lock(events_lock) do
            push!(events, (event=:skipped, testitem_id=item_id))
        end,
        on_append_output = (run_id, item_id, test_env_id, output) -> lock(outputs_lock) do
            push!(outputs, (testitem_id=item_id, output=output))
        end,
        on_attach_debugger = (run_id, pipe_name) -> nothing,
        on_process_output = (id, output) -> lock(process_outputs_lock) do
            push!(process_outputs, (process_id=id, output=output))
        end,
    )

    controller = TestItemController(callbacks; log_level=:Debug)
    test_env = TestHelpers.make_test_environment(; TestHelpers._env_kwargs(discovered)...)
    testrun_id = string(UUIDs.uuid4())

    work_units = [TestRunItem(item.id, test_env.id, nothing, :Debug) for item in output_items]

    controller_task = @async try
        run(controller)
    catch err
        @error "Controller error" exception=(err, catch_backtrace())
    end

    @info "[test] Output capture: executing testrun"
    execute_testrun(
        controller, testrun_id, [test_env],
        output_items, work_units, discovered.setups, 1, nothing
    )

    @info "[test] Output capture: shutting down"
    shutdown(controller)
    TestHelpers.timed_wait(controller_task, 120; label="output-capture-controller")

    # The test item should have passed
    passed = filter(e -> e.event == :passed, events)
    @test length(passed) == 1

    # We should have received output from the test item
    item_outputs = lock(outputs_lock) do
        filter(o -> o.testitem_id !== nothing, outputs)
    end
    combined_output = join([o.output for o in item_outputs], "")
    @test occursin("hello from output test", combined_output)
    @test occursin("second line of output", combined_output)
end
