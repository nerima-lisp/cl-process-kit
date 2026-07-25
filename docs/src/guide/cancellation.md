# Cancellation

`make-cancellation-token` creates a thread-safe token. `cancel` is
idempotent, and `cancellation-requested-p` observes its state.

```lisp
(let ((token (process-kit:make-cancellation-token)))
  (process-kit:cancel token)
  (process-kit:run-command
   (process-kit:make-command "/bin/sleep" (list "10"))
   :cancellation-token token
   :on-cancel :return))
;; => a PROCESS-RESULT whose cancelled-p is true
```

## Where a token can be passed

Pass the token as `cancellation-token` to:

- [`run`](execution.md), [`communicate`](async.md#blocking-communication),
  [`run-command`](execution.md), and
  [`run-pipeline`](pipelines.md)

!!! note "Tasks own their cancellation token"

    `communicate-async` and `run-command-async` reject an explicit
    `cancellation-token` — the returned `process-task` owns its own token,
    and `cancel-process (task)` is how you cancel it. See
    [Asynchronous Execution](async.md#event-driven-communication).

## Escalation and outcome

Cancellation sends SIGTERM to the process group, waits the grace period,
and sends SIGKILL if needed — the same process-group-wide escalation a
timeout uses, so a cancelled shell pipeline's forked descendants are
terminated too.

`on-cancel :error` (the default) signals `process-cancelled-error`;
`:return` returns a result with `process-result-cancelled-p` true. See
[Results and Conditions](../reference/results-and-conditions.md) for the
condition's full accessor list.
