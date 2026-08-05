"""
    ControllerCallbacks

Holds all callback functions for the test item controller. Passed at construction time,
shared across all test runs.

Required callbacks (must be provided):
- Test item lifecycle: started, passed, failed, errored, skipped
- Output: append_output
- Debug: attach_debugger

Optional callbacks (default to `nothing`):
- Process lifecycle: created, terminated, status_changed, output
"""
struct ControllerCallbacks{F1<:Function,F2<:Function,F3<:Function,F4<:Function,F5<:Function,F6<:Function,F7<:Function,F8<:Union{Nothing,Function},F9<:Union{Nothing,Function},F10<:Union{Nothing,Function},F11<:Union{Nothing,Function}}
    on_testitem_started::F1              # (testrun_id, testitem_id, test_env_id) -> nothing
    on_testitem_passed::F2               # (testrun_id, testitem_id, test_env_id, duration) -> nothing
    on_testitem_failed::F3               # (testrun_id, testitem_id, test_env_id, messages, duration) -> nothing
    on_testitem_errored::F4              # (testrun_id, testitem_id, test_env_id, messages, duration) -> nothing
    on_testitem_skipped::F5              # (testrun_id, testitem_id, test_env_id) -> nothing
    on_append_output::F6                 # (testrun_id, testitem_id, test_env_id, output) -> nothing
    on_attach_debugger::F7               # (testrun_id, debug_pipe_name) -> nothing
    on_process_created::F8               # (id, test_env_id) -> nothing
    on_process_terminated::F9            # (id) -> nothing
    on_process_status_changed::F10       # (id, status) -> nothing
    on_process_output::F11               # (id, output) -> nothing
end

function ControllerCallbacks(;
    on_testitem_started,
    on_testitem_passed,
    on_testitem_failed,
    on_testitem_errored,
    on_testitem_skipped,
    on_append_output,
    on_attach_debugger,
    on_process_created=nothing,
    on_process_terminated=nothing,
    on_process_status_changed=nothing,
    on_process_output=nothing,
)
    return ControllerCallbacks(
        on_testitem_started,
        on_testitem_passed,
        on_testitem_failed,
        on_testitem_errored,
        on_testitem_skipped,
        on_append_output,
        on_attach_debugger,
        on_process_created,
        on_process_terminated,
        on_process_status_changed,
        on_process_output,
    )
end
