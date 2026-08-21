# [JSONRPC API](@id JSONRPC-API)

This section documents the JSONRPC wire protocol exposed by
[`JSONRPCTestItemController`](@ref). It is the integration path used by the
VS Code Julia extension and any other host that communicates over a pair of
I/O streams (typically named pipes).

## Overview

```@docs
TestItemControllers.JSONRPCTestItemController
```

The transport uses the [JSONRPC 2.0](https://www.jsonrpc.org/specification)
framing with `Content-Length` headers, the same encoding used by the
Language Server Protocol. All payloads are JSON objects with **camelCase**
field names (the controller converts them to/from the snake\_case Julia types
described in [Julia API](@ref)).

The host connects a pair of I/O streams (e.g. `stdin`/`stdout` of the
controller process, or a named pipe) and sends *requests*. The controller
replies to each request and independently sends *notifications* for progress
events.

## Requests

### `createTestRun`

Start a new test run. The request blocks on the server side until all work
units complete (or are cancelled), then returns the response.

**Parameters** (`CreateTestRunParams`):

| Field | Type | Description |
|:------|:-----|:------------|
| `testRunId` | `String` | Unique identifier for this run. |
| `testEnvironments` | `Array<TestEnvironment>` | Julia process configurations (see below). |
| `testItems` | `Array<TestItemDetail>` | Metadata for every referenced test item. |
| `workUnits` | `Array<TestRunItem>` | The (test item, environment) pairs to execute. |
| `testSetups` | `Array<TestSetupDetail>` | Setup/module blocks needed by the test items. |
| `maxProcessCount` | `Integer` | Upper bound on concurrent child processes. |
| `coverageRootUris` | `Array<String> \| null` | Optional URI prefixes to limit coverage collection. |

**Response** (`CreateTestRunResponse`):

| Field | Type | Description |
|:------|:-----|:------------|
| `status` | `String` | `"success"` on normal completion. |
| `coverage` | `Array<FileCoverage> \| null` | Per-file coverage data, or `null` if no coverage was collected. |

### `terminateTestProcess`

Kill a specific child process.

**Parameters** (`TerminateTestProcessParams`):

| Field | Type | Description |
|:------|:-----|:------------|
| `testProcessId` | `String` | The process ID to terminate. |

**Response**: `null`

## Notifications (client → server)

### `shutdown`

Ask the controller to shut down: every active test run is cancelled, every child
process is terminated (a process that does not exit within the grace period is
force-killed), and the controller exits once they are gone. No parameters.

The controller also shuts itself down in exactly the same way when the client's
connection closes without a `shutdown` — the client exiting or crashing — so test
processes never outlive their client. Sending `shutdown` first is still preferable:
it lets the client observe the `testProcessTerminated` notifications.

## Notifications (server → client)

The controller sends the following notifications as test execution progresses.
All are fire-and-forget (no response expected).

### Test item lifecycle

Each test item produces exactly one terminal notification (`testItemPassed`,
`testItemFailed`, `testItemErrored` or `testItemSkipped`) per run, preceded by at
most one `testItemStarted`.

Identify an item by the pair `(testItemId, testEnvId)`, not by `testItemId` alone.
A test item id is scoped to its package, so the same package checked out into two
folders — two worktrees, or a vendored copy beside a dev checkout — mints the same
id from both. A client keying on the id alone collapses the two: one item's results
arrive twice while the other never resolves.

#### `testItemStarted`

| Field | Type | Description |
|:------|:-----|:------------|
| `testRunId` | `String` | Run that owns this item. |
| `testItemId` | `String` | The test item that started. |
| `testEnvId` | `String` | Environment the item is running under. |

#### `testItemPassed`

| Field | Type | Description |
|:------|:-----|:------------|
| `testRunId` | `String` | |
| `testItemId` | `String` | |
| `testEnvId` | `String` | |
| `duration` | `Float \| null` | Wall-clock milliseconds. |
| `perf` | `PerfStats \| null` | Execution statistics, when the test process measured them. |

#### `testItemFailed`

| Field | Type | Description |
|:------|:-----|:------------|
| `testRunId` | `String` | |
| `testItemId` | `String` | |
| `testEnvId` | `String` | |
| `messages` | `Array<TestMessage>` | Failure details (see below). |
| `duration` | `Float \| null` | Wall-clock milliseconds. |
| `perf` | `PerfStats \| null` | Execution statistics, when the test process measured them. |

#### `testItemErrored`

| Field | Type | Description |
|:------|:-----|:------------|
| `testRunId` | `String` | |
| `testItemId` | `String` | |
| `testEnvId` | `String` | |
| `messages` | `Array<TestMessage>` | Error details. |
| `duration` | `Float \| null` | Wall-clock milliseconds, or `null` when the controller synthesised the result (timeout, crash, activation failure). |
| `perf` | `PerfStats \| null` | Execution statistics, when the test process measured them. |

#### `testItemSkipped`

| Field | Type | Description |
|:------|:-----|:------------|
| `testRunId` | `String` | |
| `testItemId` | `String` | |
| `testEnvId` | `String` | |
| `reason` | `String \| null` | Source text of the `skip` expression that evaluated to `true`. `null` when the item was skipped for another reason, such as cancellation. |

### Output

#### `appendOutput`

| Field | Type | Description |
|:------|:-----|:------------|
| `testRunId` | `String` | |
| `testItemId` | `String \| null` | `null` for process-level output. |
| `testEnvId` | `String` | Always present, including for process-level output. |
| `output` | `String` | Captured `stdout`/`stderr` text. |

### Debug

#### `launchDebugger`

| Field | Type | Description |
|:------|:-----|:------------|
| `testRunId` | `String` | |
| `debugPipeName` | `String` | Named pipe for attaching a debug adapter. |

### Process lifecycle

#### `testProcessCreated`

| Field | Type | Description |
|:------|:-----|:------------|
| `id` | `String` | Process identifier. |
| `packageName` | `String` | Package under test. |
| `packageUri` | `String \| null` | File URI of the package root. |
| `projectUri` | `String \| null` | File URI of the custom project, if any. |
| `coverage` | `Boolean` | Whether coverage is enabled. |
| `env` | `Object<String, String \| null>` | Environment variables. |

#### `testProcessTerminated`

| Field | Type | Description |
|:------|:-----|:------------|
| `id` | `String` | Process that exited. |

#### `testProcessStatusChanged`

| Field | Type | Description |
|:------|:-----|:------------|
| `id` | `String` | |
| `status` | `String` | New status label (e.g. `"Activating"`, `"Running"`, `"Idle"`). |

#### `testProcessOutput`

| Field | Type | Description |
|:------|:-----|:------------|
| `id` | `String` | |
| `output` | `String` | Raw output text. |

## Wire-format types

The tables below list the JSON shapes for compound types that appear in
requests and notifications. All field names are **camelCase** on the wire;
the controller converts them to/from the snake\_case Julia types in
the [Julia API](@ref) section.

### `TestEnvironment`

| Field | Type | Description |
|:------|:-----|:------------|
| `id` | `String` | |
| `juliaCmd` | `String` | Path to Julia executable. |
| `juliaArgs` | `Array<String>` | Extra CLI flags. |
| `juliaNumThreads` | `String \| null` | `JULIA_NUM_THREADS` value. |
| `juliaEnv` | `Object<String, String \| null>` | Additional env vars. |
| `mode` | `String` | `"Normal"`, `"Coverage"`, or `"Debug"`. |
| `packageName` | `String` | |
| `packageUri` | `String` | |
| `projectUri` | `String \| null` | |
| `envContentHash` | `String \| null` | |
| `checkBounds` | `String \| null` | Value for the `--check-bounds` flag. |

### `TestRunItem`

| Field | Type | Description |
|:------|:-----|:------------|
| `testitemId` | `String` | |
| `testEnvId` | `String` | |
| `timeout` | `Float \| null` | Seconds. |
| `logLevel` | `String` | e.g. `"Info"`, `"Debug"`. |

### `TestItemDetail`

| Field | Type | Description |
|:------|:-----|:------------|
| `id` | `String` | |
| `uri` | `String` | |
| `label` | `String` | |
| `packageName` | `String` | |
| `packageUri` | `String` | |
| `useDefaultUsings` | `Boolean` | |
| `testSetups` | `Array<String>` | |
| `line` | `Integer` | |
| `column` | `Integer` | |
| `code` | `String` | |
| `codeLine` | `Integer` | |
| `codeColumn` | `Integer` | |
| `optionSkip` | `Boolean \| String \| null` | The `skip` kwarg: `true`/`false` for a literal, or the source text of an expression the test process evaluates immediately before the item would run. Absent means `false`. |

### `TestSetupDetail`

| Field | Type | Description |
|:------|:-----|:------------|
| `packageUri` | `String` | |
| `name` | `String` | |
| `kind` | `String` | |
| `uri` | `String` | |
| `line` | `Integer` | |
| `column` | `Integer` | |
| `code` | `String` | |

### `TestMessage`

| Field | Type | Description |
|:------|:-----|:------------|
| `message` | `String` | Failure/error description. |
| `expectedOutput` | `String \| null` | |
| `actualOutput` | `String \| null` | |
| `uri` | `String \| null` | |
| `line` | `Integer \| null` | |
| `column` | `Integer \| null` | |
| `stackTrace` | `Array<TestMessageStackFrame> \| null` | |

### `TestMessageStackFrame`

| Field | Type | Description |
|:------|:-----|:------------|
| `label` | `String` | |
| `uri` | `String \| null` | |
| `line` | `Integer \| null` | |
| `column` | `Integer \| null` | |

### `PerfStats`

Execution statistics for one test item, as measured by the test process. Every
field is optional: `elapsed`, `bytes`, `allocs` and `gctime` are always available,
while the compile timings depend on Julia internals that not every version the
test process supports provides.

| Field | Type | Description |
|:------|:-----|:------------|
| `elapsed` | `Float \| null` | Wall-clock milliseconds. |
| `bytes` | `Integer \| null` | Bytes allocated. |
| `allocs` | `Integer \| null` | Number of allocations. |
| `gctime` | `Float \| null` | Milliseconds spent in GC. |
| `compileTime` | `Float \| null` | Milliseconds spent compiling. |
| `recompileTime` | `Float \| null` | Milliseconds spent recompiling. |

### `FileCoverage`

| Field | Type | Description |
|:------|:-----|:------------|
| `uri` | `String` | |
| `coverage` | `Array<Integer \| null>` | Per-line execution counts (`null` = not instrumentable). |
