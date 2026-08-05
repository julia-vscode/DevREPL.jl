# [Internals](@id Internals)

This section documents the internal architecture of TestItemControllers.jl.
It is intended for contributors and advanced users who want to understand how
the controller orchestrates test execution.

## Architecture overview

TestItemControllers.jl implements a **message-driven reactor** pattern.
A single-threaded event loop processes messages from an unbounded channel,
mutating controller state in response. All async I/O (process spawning,
JSONRPC communication with child processes, timeout timers) runs on separate
tasks that post messages back to the reactor channel rather than touching
shared state directly. This design eliminates data races while keeping the
programming model straightforward.

```
┌─────────────┐   ReactorMessage   ┌─────────────────────┐
│  IO tasks   │ ─────────────────► │                     │
│  (per proc) │                    │   Reactor loop      │
├─────────────┤                    │   handle!(ctrl,msg) │
│ execute_    │ ─────────────────► │                     │
│ testrun()   │  GetProcsForTestRun├─────────────────────┘
├─────────────┤                    │       │
│ cancel /    │ ─────────────────► │       ▼
│ shutdown    │  ShutdownMsg       │  State mutation
└─────────────┘                    │  (FSMs, pools, runs)
                                   │       │
                                   │       ▼
                                   │  Callbacks
                                   │  (on_testitem_passed, etc.)
```

## Reactor event loop

The reactor lives in `Base.run(controller::TestItemController)`. It calls
`take!(controller.reactor_channel)` in a loop, dispatching each message to
the appropriate `handle!(controller, msg)` method. The loop exits when
`handle!` returns `true` (which only happens after a shutdown completes and
all processes are dead).

### ReactorMessage hierarchy

All messages inherit from the abstract type `ReactorMessage`. They are grouped
into three categories:

**Controller-level messages**

| Message | Purpose |
|:--------|:--------|
| `ShutdownMsg` | Request orderly shutdown. Cancels all runs, kills all processes. |
| `GetProcsForTestRunMsg` | Acquire processes for a new test run from the pool. |
| `ReturnToPoolMsg` | Return an idle process to the pool after a run completes. |
| `TestProcessTerminatedMsg` | A child process exited (clean or crash). |
| `TerminateTestProcessMsg` | User-requested process termination. |
| `TestProcessStatusChangedMsg` | Forward process status change to the host. |
| `TestProcessOutputMsg` | Forward raw process output to the host. |

**Test-run messages**

| Message | Purpose |
|:--------|:--------|
| `ProcsAcquiredMsg` | Processes are ready; transition run to `ProcsAcquired`. |
| `TestRunCancelledMsg` | Cancellation token fired; abort the run. |
| `ReadyToRunTestItemsMsg` | A process finished setup and is ready to run items. |
| `PrecompileDoneMsg` | Environment precompilation completed. |
| `AttachDebuggerMsg` | A process is ready for debugger attachment. |
| `TestItemStartedMsg` | A test item began executing. |
| `TestItemPassedMsg` | A test item passed. |
| `TestItemFailedMsg` | A test item failed (assertion errors). |
| `TestItemErroredMsg` | A test item threw an exception. |
| `TestItemSkippedStolenMsg` | A stolen item was skipped (work stealing). |
| `TestItemTimeoutMsg` | A test item exceeded its timeout. |
| `AppendOutputMsg` | Captured output for a test item or process. |

**Process-lifecycle messages** (from IO tasks)

| Message | Purpose |
|:--------|:--------|
| `TestProcessLaunchedMsg` | Child process started; carries the `Process` handle and JSONRPC endpoint. |
| `TestProcessActivatedMsg` | Environment activation completed. |
| `TestProcessTestSetupsLoadedMsg` | Test setups loaded. |
| `TestProcessReviseResultMsg` | Revise completed; reports whether a restart is needed. |
| `TestProcessIOErrorMsg` | IO error on the process pipe (`:restart` or `:fatal`). |
| `ActivationFailedMsg` | Environment activation failed. |

## Finite state machines

The controller tracks lifecycle phases using three enum-based FSMs. Each FSM
is an instance of `FSM{S}` which stores the current state, an allowed
transition table, and validates every `transition!()` call.

### ControllerPhase

```
ControllerRunning → ControllerShuttingDown → ControllerStopped
```

- **Running**: Normal operation, accepts new test runs.
- **ShuttingDown**: Rejects new runs, cancels active runs, drains the process pool.
- **Stopped**: Reactor loop breaks.

### TestProcessPhase

```
ProcessCreated
  ├→ ProcessIdle
  └→ ProcessReviseOrStart
       ├→ ProcessRevising → ProcessStarting / ProcessActivatingEnv / ProcessConfiguringTestRun
       └→ ProcessStarting → ProcessWaitingForPrecompile / ProcessActivatingEnv / ProcessIdle
                              └→ ProcessActivatingEnv → ProcessConfiguringTestRun
                                                         └→ ProcessReadyToRun → ProcessRunning → ProcessIdle
ProcessDead  (reachable from ANY state except itself)
```

The 11 states model the full lifecycle of a child Julia process:

| State | Description |
|:------|:------------|
| `ProcessCreated` | Entry state; process launch requested but not yet started. |
| `ProcessIdle` | Process is in the pool, waiting for work. |
| `ProcessReviseOrStart` | Decision point: reuse via Revise or restart from scratch. |
| `ProcessRevising` | Running `Revise.revise()` in the child process. |
| `ProcessStarting` | Launching a new Julia child process. |
| `ProcessWaitingForPrecompile` | Waiting for environment precompilation to finish. |
| `ProcessActivatingEnv` | Activating the package environment in the child process. |
| `ProcessConfiguringTestRun` | Sending test run configuration (setups, coverage settings). |
| `ProcessReadyToRun` | Configured and ready to receive test items. |
| `ProcessRunning` | Executing test items. |
| `ProcessDead` | Terminal state; process exited or was killed. |

Any state (except `ProcessDead`) can also transition to `ProcessStarting` for
error recovery (restart).

### TestRunPhase

```
TestRunCreated → TestRunWaitingForProcs → TestRunProcsAcquired → TestRunRunning → TestRunCompleted
                          └→ TestRunCancelled  (from any non-terminal state)
```

| State | Description |
|:------|:------------|
| `TestRunCreated` | Run registered, not yet requesting processes. |
| `TestRunWaitingForProcs` | Waiting for the pool to provide processes. |
| `TestRunProcsAcquired` | Processes assigned; configuring them for this run. |
| `TestRunRunning` | Test items are being dispatched and executed. |
| `TestRunCompleted` | All work units finished. |
| `TestRunCancelled` | Run was cancelled (timeout, user request, or shutdown). |

## Process management

### ProcessEnv

`ProcessEnv` is an internal struct that serves as the dictionary key for the
process pool. It captures the subset of [`TestEnvironment`](@ref) fields that
determine process identity: `project_uri`, `package_uri`, `package_name`,
`juliaCmd`, `juliaArgs`, `juliaNumThreads`, `mode`, and `env`. Custom `hash`
and `==` methods ensure that two environments with the same configuration
share a pool slot.

### Process pool

The controller maintains a pool `Dict{ProcessEnv, Vector{String}}` mapping
each environment configuration to a list of idle process IDs. When
[`execute_testrun`](@ref) requests processes:

1. The reactor checks the pool for idle processes matching each `ProcessEnv`.
2. Reusable processes go through a **Revise check** — if the `env_content_hash`
   hasn't changed, Revise hot-reloads the code. If it has changed, the process
   is killed and a fresh one is launched.
3. New processes are launched to fill any remaining demand.
4. After a test run completes, processes are returned to the pool via
   `ReturnToPoolMsg`.

### Process launch

Each child process is a Julia instance started with:
- `--check-bounds=yes`, `--startup-file=no`, `--history-file=no`, `--depwarn=no`
- `--code-coverage=user` (when `mode == "Coverage"`) or `--code-coverage=none`
- Custom environment variables from `TestEnvironment.julia_env`

The child loads `testprocess/app/testserver_main.jl` which starts a
`TestItemServer` that communicates with the controller over a named-pipe
JSONRPC connection.

### Output demultiplexing

Child processes interleave output from multiple test items on a single
`stdout` stream. The controller uses sentinel markers
(`\x1f3805a0ad41b54562a46add40be31ca27` and
`\x1f4031af828c3d406ca42e25628bb0aa77`) embedded in the output to associate
each chunk with the correct test item. The IO task in `testprocess.jl`
parses these markers and dispatches `AppendOutputMsg` messages to the reactor.

## Test run lifecycle

A test run proceeds through these stages:

1. **Creation** — `execute_testrun()` builds a `TestRunState`, registers it
   with the controller, and posts a `GetProcsForTestRunMsg`.

2. **Process acquisition** — The reactor assigns processes from the pool
   (or launches new ones) and posts `ProcsAcquiredMsg`.

3. **Configuration** — Each assigned process goes through environment
   activation, optional Revise, test setup loading, and test run configuration
   (sending the list of setups and coverage settings to the child process).

4. **Execution** — Processes call the child's `runTestItems` RPC, which
   executes test items and sends back `started`/`passed`/`failed`/`errored`
   notifications.

5. **Work stealing** — When a process finishes its assigned items, it can
   steal remaining items from other processes via the `stealTestItems` RPC.

6. **Completion** — When all work units are done (or the run is cancelled),
   coverage data is aggregated and the result is put into the run's
   `completion_channel`, which `execute_testrun()` is blocking on.

### Cancellation and timeouts

- Each test run has a `CancellationTokenSource`. If the caller's token fires,
  a bridge registration posts `TestRunCancelledMsg` to the reactor.
- Per-item timeouts are implemented via `CancellationTokens.register()` on a
  per-process timeout source. When a timeout fires, `TestItemTimeoutMsg` is
  posted and the process is killed.

## Controller ↔ TestServer protocol

Communication between the controller and each child Julia process uses a
second JSONRPC layer defined in `TestItemServerProtocol` (in
`shared/testserver_protocol.jl`).

### Requests (controller → child process)

| Method | Description |
|:-------|:------------|
| `activateEnv` | Activate the package environment and load imports. |
| `testserver/revise` | Run `Revise.revise()` and report whether a restart is needed. |
| `testserver/ConfigureTestRun` | Send test setups, coverage settings, and log level. |
| `testserver/runTestItems` | Execute a batch of test items. |
| `testserver/stealTestItems` | Steal remaining items from another process. |
| `testserver/shutdown` | Gracefully shut down the child process. |

### Notifications (child process → controller)

| Method | Description |
|:-------|:------------|
| `started` | A test item began executing. |
| `passed` | A test item passed (with duration). |
| `failed` | A test item failed (with messages and duration). |
| `errored` | A test item threw an exception (with messages and duration). |
| `skippedStolen` | A stolen item was skipped. |

These notifications are received by the per-process IO task and translated
into `ReactorMessage` subtypes that the reactor dispatches.

## Coverage collection

When `TestEnvironment.mode` is `"Coverage"`, the child process runs with
`--code-coverage=user`. After each test item completes, the child sends
coverage data back. The controller aggregates `FileCoverage` entries across
all processes and work units, optionally filtering by `coverage_root_uris`.
The aggregated result is returned from [`execute_testrun`](@ref).

## Vendored packages

TestItemControllers.jl vendors its dependencies in the `packages/` directory
using git subtrees. This includes `JSONRPC`, `JSON`, `CancellationTokens`,
`URIParser`, `CoverageTools`, `Revise`, `CodeTracking`, `JuliaInterpreter`,
`LoweredCodeUtils`, `DebugAdapter`, `OrderedCollections`, `Preferences`,
`TestEnv`, and `Compiler`. Vendoring allows the package to work without
requiring users to install these dependencies and avoids version conflicts
with other packages in the user's environment.

The `packages/` subtrees are updated via `scripts/update_vendored_packages.jl`.

## Version-specific environments

The `testprocess/environments/` directory contains per-Julia-version
`Project.toml` and `Manifest.toml` files (`v1.0/` through `v1.13/`, plus a
`fallback/`). These pin the exact dependency versions used by the test server
for each Julia minor version, ensuring reproducible behavior across the
supported Julia version range.
