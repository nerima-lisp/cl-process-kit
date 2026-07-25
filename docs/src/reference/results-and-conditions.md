# Results and Conditions

## `process-result`

`process-result` has accessors for `program`, `arguments`, `pid`, `status`,
`duration-seconds`, `exit-code`, `stdout`, `stderr`, `timed-out-p`,
`cancelled-p`, `signal`, `stdout-truncated-p`, and `stderr-truncated-p`.

`process-success-p` is true only for a normal status-0 exit that neither
timed out nor was cancelled.

`make-process-result` is the raw struct constructor behind every result
`run-command`, `communicate`, and the PTY backend hand back. It is exported
for callers that need to fabricate a `process-result` directly — for
example, a `cl-weave:with-mocked-functions` stub standing in for `run` in a
unit test — rather than by launching a real process.

## `pipeline-result`

See [Pipelines](../guide/pipelines.md#reading-results) for
`pipeline-result-stdout`, `pipeline-result-results`,
`pipeline-result-stderr`, `pipeline-result-timed-out-p`,
`pipeline-result-cancelled-p`, and `pipeline-result-duration-seconds`.

## Timeout and cancellation outcomes

Timeout and cancellation terminate the entire isolated process group using
SIGTERM followed by SIGKILL after the grace period. For both,
`on-timeout`/`on-cancel` selects either a condition (`:error`) or a returned
result (`:return`).

Non-zero exits are returned normally by `run` and `run-command`; use
`run/checked` or `run-command/checked` when they should signal
`process-exit-error`. Use `run-pipeline/checked` to signal
`pipeline-exit-error` for the first unsuccessful pipeline stage.

## Condition hierarchy

All library conditions inherit from `process-error`:

| Condition | Accessors |
| --- | --- |
| `process-launch-error` | `program`, `arguments`, `directory`, `cause` |
| `process-exit-error` | `result` |
| `pipeline-exit-error` | `result`, `stage-index`, `stage-result` |
| `process-timeout-error` | `command`, `args`, `timeout`, `result`, `stage-index`, `pipeline-result` |
| `process-cancelled-error` | `result`, `stage-index`, `pipeline-result` |
| `communicate-options-mismatch` | `process`, `expected-options`, `actual-options` |
| `process-group-isolation-error` | `pid`, `pgid` |
| `process-io-error` | `stream`, `cause` |

`process-timeout-error` and `process-cancelled-error` retain
`stage-index`/`pipeline-result` so a handler can tell whether the condition
came from a bare `run`/`run-command` call or from a stage inside
[`run-pipeline`](../guide/pipelines.md) — see that page's *Failure
diagnostics* section for how those readers are populated stage by stage.

`communicate-options-mismatch` is signalled when a second `communicate`
call on the same handle passes different, non-matching options than the
first — see [Blocking communication](../guide/async.md#blocking-communication).
