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

## Notifications (server → client)

The controller sends the following notifications as test execution progresses.
All are fire-and-forget (no response expected).

### Test item lifecycle

#### `testItemStarted`

| Field | Type | Description |
|:------|:-----|:------------|
| `testRunId` | `String` | Run that owns this item. |
| `testItemId` | `String` | The test item that started. |

#### `testItemPassed`

| Field | Type | Description |
|:------|:-----|:------------|
| `testRunId` | `String` | |
| `testItemId` | `String` | |
| `duration` | `Float \| null` | Wall-clock seconds. |

#### `testItemFailed`

| Field | Type | Description |
|:------|:-----|:------------|
| `testRunId` | `String` | |
| `testItemId` | `String` | |
| `messages` | `Array<TestMessage>` | Failure details (see below). |
| `duration` | `Float \| null` | Wall-clock seconds. |

#### `testItemErrored`

| Field | Type | Description |
|:------|:-----|:------------|
| `testRunId` | `String` | |
| `testItemId` | `String` | |
| `messages` | `Array<TestMessage>` | Error details. |
| `duration` | `Float \| null` | Wall-clock seconds. |

#### `testItemSkipped`

| Field | Type | Description |
|:------|:-----|:------------|
| `testRunId` | `String` | |
| `testItemId` | `String` | |

### Output

#### `appendOutput`

| Field | Type | Description |
|:------|:-----|:------------|
| `testRunId` | `String` | |
| `testItemId` | `String \| null` | `null` for process-level output. |
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

### `FileCoverage`

| Field | Type | Description |
|:------|:-----|:------------|
| `uri` | `String` | |
| `coverage` | `Array<Integer \| null>` | Per-line execution counts (`null` = not instrumentable). |
