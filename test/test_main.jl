@testitem "TestItemController run and shutdown" begin
    using TestItemControllers: ControllerCallbacks

    callbacks = ControllerCallbacks(
        on_testitem_started = (run_id, item_id, test_env_id) -> nothing,
        on_testitem_passed = (run_id, item_id, test_env_id, duration) -> nothing,
        on_testitem_failed = (run_id, item_id, test_env_id, messages, duration) -> nothing,
        on_testitem_errored = (run_id, item_id, test_env_id, messages, duration) -> nothing,
        on_testitem_skipped = (run_id, item_id, test_env_id) -> nothing,
        on_append_output = (run_id, item_id, test_env_id, output) -> nothing,
        on_attach_debugger = (run_id, pipe_name) -> nothing,
    )

    tic = TestItemController(callbacks; log_level=:Debug)

    finished = Channel(1)

    @async try
        run(tic)

        put!(finished, true)
    catch err
        Base.display_error(err, catch_backtrace())
    end

    shutdown(tic)

    @test fetch(finished)
end
