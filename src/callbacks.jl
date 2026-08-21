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

`duration` is **milliseconds**, or `nothing` when the controller synthesises a result the
test process never reported (timeout, crash, environment activation failure).

Each test item produces exactly one terminal callback (passed, failed, errored or skipped)
per run, preceded by at most one `started`. Speculative work stealing means an item can
genuinely execute on two processes at once, but the controller discards everything the
non-owning process reports, so consumers never see a duplicate or a status going backwards.

The terminal callbacks take one optional trailing argument beyond what is listed above: a
[`PerfStats`](@ref) (or `nothing`) for passed/failed/errored, and a skip reason (or
`nothing`) for skipped. Callbacks that do not accept it keep working unchanged — the
controller invokes them through its internal `_notify_testitem_*` helpers, which fall
back to the shorter arity.
"""
struct ControllerCallbacks{F1<:Function,F2<:Function,F3<:Function,F4<:Function,F5<:Function,F6<:Function,F7<:Function,F8<:Union{Nothing,Function},F9<:Union{Nothing,Function},F10<:Union{Nothing,Function},F11<:Union{Nothing,Function}}
    on_testitem_started::F1              # (testrun_id, testitem_id, test_env_id) -> nothing
    on_testitem_passed::F2               # (testrun_id, testitem_id, test_env_id, duration[, perf]) -> nothing
    on_testitem_failed::F3               # (testrun_id, testitem_id, test_env_id, messages, duration[, perf]) -> nothing
    on_testitem_errored::F4              # (testrun_id, testitem_id, test_env_id, messages, duration[, perf]) -> nothing
    on_testitem_skipped::F5              # (testrun_id, testitem_id, test_env_id[, reason]) -> nothing
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

"""
    _call_with_optional(f, args...; extra)

Call `f(args..., extra)` when `f` accepts that many arguments, otherwise `f(args...)`.

This is how the terminal callbacks grew a trailing argument without breaking the callbacks
every existing consumer already passes: a four-argument `on_testitem_passed` is simply not
applicable to five arguments, so it keeps being called with four.
"""
function _call_with_optional(@nospecialize(f), args...; extra)
    if applicable(f, args..., extra)
        return f(args..., extra)
    else
        return f(args...)
    end
end

_notify_testitem_passed(cb::ControllerCallbacks, testrun_id, testitem_id, test_env_id, duration, perf=nothing) =
    _call_with_optional(cb.on_testitem_passed, testrun_id, testitem_id, test_env_id, duration; extra=perf)

_notify_testitem_failed(cb::ControllerCallbacks, testrun_id, testitem_id, test_env_id, messages, duration, perf=nothing) =
    _call_with_optional(cb.on_testitem_failed, testrun_id, testitem_id, test_env_id, messages, duration; extra=perf)

_notify_testitem_errored(cb::ControllerCallbacks, testrun_id, testitem_id, test_env_id, messages, duration, perf=nothing) =
    _call_with_optional(cb.on_testitem_errored, testrun_id, testitem_id, test_env_id, messages, duration; extra=perf)

_notify_testitem_skipped(cb::ControllerCallbacks, testrun_id, testitem_id, test_env_id, reason=nothing) =
    _call_with_optional(cb.on_testitem_skipped, testrun_id, testitem_id, test_env_id; extra=reason)
