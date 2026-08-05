# [Julia API](@id Julia-API)

This section documents the native Julia API for TestItemControllers.jl.
Use this API when you want to drive test execution directly from Julia code
(e.g. from a CLI tool, REPL dashboard, or custom integration).

## Quick start

```julia
using TestItemControllers

# 1. Define callbacks
callbacks = ControllerCallbacks(
    on_testitem_started  = (testrun_id, testitem_id, test_env_id) -> @info("started", testitem_id),
    on_testitem_passed   = (testrun_id, testitem_id, test_env_id, duration) -> @info("passed", testitem_id, duration),
    on_testitem_failed   = (testrun_id, testitem_id, test_env_id, messages, duration) -> @warn("failed", testitem_id),
    on_testitem_errored  = (testrun_id, testitem_id, test_env_id, messages, duration) -> @error("errored", testitem_id),
    on_testitem_skipped  = (testrun_id, testitem_id, test_env_id) -> @info("skipped", testitem_id),
    on_append_output     = (testrun_id, testitem_id, test_env_id, output) -> print(output),
    on_attach_debugger   = (testrun_id, debug_pipe_name) -> nothing,
)

# 2. Create and start the controller
ctrl = TestItemController(callbacks)
reactor_task = @async run(ctrl)

# 3. Build test run parameters
env = TestEnvironment(
    "env-1",                      # id
    "julia",                      # julia_cmd
    String[],                     # julia_args
    nothing,                      # julia_num_threads
    Dict{String,Union{String,Nothing}}(),  # julia_env
    "Normal",                     # mode
    "MyPackage",                  # package_name
    "file:///path/to/MyPackage",  # package_uri
    nothing,                      # project_uri
    nothing,                      # env_content_hash
)

item = TestItemDetail(
    "item-1",                     # id
    "file:///path/to/test.jl",    # uri
    "my test",                    # label
    "MyPackage",                  # package_name
    "file:///path/to/MyPackage",  # package_uri
    true,                         # option_default_imports
    String[],                     # test_setups
    1,                            # line
    1,                            # column
    "@test 1 + 1 == 2",          # code
    1,                            # code_line
    1,                            # code_column
)

work = TestRunItem("item-1", "env-1", nothing, :Info)

# 4. Execute (blocks until complete)
coverage = execute_testrun(ctrl, "run-1", [env], [item], [work], TestSetupDetail[], 2, nothing)

# 5. Shut down
shutdown(ctrl)
wait_for_shutdown(ctrl, reactor_task)
```

## Controller

```@docs
TestItemControllers.TestItemController
```

```@docs
TestItemControllers.shutdown
```

```@docs
TestItemControllers.wait_for_shutdown
```

```@docs
TestItemControllers.terminate_test_process
```

```@docs
TestItemControllers.execute_testrun
```

## Callbacks

```@docs
TestItemControllers.ControllerCallbacks
```

### Required callbacks

Every [`ControllerCallbacks`](@ref) must provide these functions:

| Callback | Signature | Description |
|:---------|:----------|:------------|
| `on_testitem_started` | `(testrun_id, testitem_id, test_env_id) -> nothing` | Fired when a test item begins execution. |
| `on_testitem_passed` | `(testrun_id, testitem_id, test_env_id, duration) -> nothing` | Fired when a test item passes. `duration` is seconds. |
| `on_testitem_failed` | `(testrun_id, testitem_id, test_env_id, messages, duration) -> nothing` | Fired when a test item has assertion failures. `messages` is a `Vector{TestMessage}`. |
| `on_testitem_errored` | `(testrun_id, testitem_id, test_env_id, messages, duration) -> nothing` | Fired when a test item throws an unhandled exception. |
| `on_testitem_skipped` | `(testrun_id, testitem_id, test_env_id) -> nothing` | Fired when a test item is skipped (e.g. due to cancellation). |
| `on_append_output` | `(testrun_id, testitem_id, test_env_id, output) -> nothing` | Captured `stdout`/`stderr` output. `testitem_id` may be `nothing` for process-level output. |
| `on_attach_debugger` | `(testrun_id, debug_pipe_name) -> nothing` | Fired when a process is ready for a debug adapter to attach. |

### Optional callbacks

These default to `nothing` (disabled) and can be provided for process-level telemetry:

| Callback | Signature | Description |
|:---------|:----------|:------------|
| `on_process_created` | `(id, test_env_id) -> nothing` | A new child process was spawned. |
| `on_process_terminated` | `(id) -> nothing` | A child process exited. |
| `on_process_status_changed` | `(id, status) -> nothing` | Process status label changed (e.g. `"Activating"`, `"Running"`). |
| `on_process_output` | `(id, output) -> nothing` | Raw process output not associated with a specific test item. |

## Data types

```@docs
TestItemControllers.TestEnvironment
```

```@docs
TestItemControllers.TestRunItem
```

```@docs
TestItemControllers.TestItemDetail
```

```@docs
TestItemControllers.TestSetupDetail
```

```@docs
TestItemControllers.TestMessage
```

```@docs
TestItemControllers.TestMessageStackFrame
```

```@docs
TestItemControllers.FileCoverage
```
