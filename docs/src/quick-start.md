# Quick Start

This page walks through the API surface end to end: a plain synchronous run,
a timeout that escalates SIGTERM → SIGKILL, cooperative cancellation, the
low-level asynchronous primitive, and a pipeline. Each example builds on the
last — see the [Guide](guide/command-specs.md) section for the full option
reference behind each call.

## A synchronous run

```lisp
(let ((command (process-kit:make-command
                "/usr/bin/printf" (list "%s\n" "hello, world")
                :stdout :capture
                :stderr :capture)))
  (process-kit:run-command command))
;; => a PROCESS-RESULT whose stdout is "hello, world\n"
```

`make-command` builds an immutable `command-spec`; `run-command` launches it
and blocks until it exits (or the deadline you gave it fires). For a
one-shot call, skip the intermediate `command-spec` and call
[`run`](guide/execution.md) directly with a program and argument list.

## Timeouts and escalation

A command that runs too long is escalated SIGTERM → SIGKILL and, by default,
signals a condition:

```lisp
(handler-case
    (process-kit:run "sleep" (list "10") :timeout 1)
  (process-kit:process-timeout-error (e)
    (format t "timed out after ~a seconds~%"
            (process-kit:process-timeout-error-timeout e))))
```

Or ask for a result instead of a condition with `:on-timeout :return`:

```lisp
(let ((result (process-kit:run "sleep" (list "10")
                                :timeout 1
                                :on-timeout :return)))
  (process-kit:process-result-timed-out-p result)) ;; => T
```

## Cancellation

Cancellation is cooperative at the API boundary and terminates the command's
whole process group, not just its immediate child:

```lisp
(let ((token (process-kit:make-cancellation-token)))
  (process-kit:cancel token)
  (process-kit:run-command
   (process-kit:make-command "/bin/sleep" (list "10"))
   :cancellation-token token
   :on-cancel :return))
;; => a PROCESS-RESULT whose cancelled-p is true
```

See [Cancellation](guide/cancellation.md) for the escalation timing and how
tokens compose with `communicate-async` tasks.

## Streaming output yourself

`spawn`/`spawn-command` are the low-level async primitive for callers who
want to drive the process themselves instead of letting `run`/`communicate`
manage it end to end. `with-process` terminates/reaps the child and closes
its streams on exit:

```lisp
(process-kit:with-process
    (process (process-kit:spawn-command
              (process-kit:make-command
               "/usr/bin/printf" (list "hello\n")
               :stdout :pipe)))
  (read-line (process-kit:process-output process)))
```

See [Asynchronous Execution](guide/async.md) for the full `process-handle`
surface and the event-driven `process-task` API.

## Pipelines

A pipeline captures the final stage's stdout and every stage's stderr:

```lisp
(process-kit:run-pipeline
 (list (process-kit:make-command "/usr/bin/printf" (list "c\nb\na\n"))
       (process-kit:make-command "/usr/bin/sort" nil)))
;; => a PIPELINE-RESULT whose stdout is "a\nb\nc\n"
```

See [Pipelines](guide/pipelines.md) for stage wiring details and
`run-pipeline/checked`.

## Where to next

- [Command Specifications](guide/command-specs.md) — every `make-command`
  option, environment/search resolution rules, and accessors.
- [Synchronous Execution](guide/execution.md) — `run`, `run/checked`,
  `run-shell`, `run-command`, `run-command/checked`, `run-command-async`.
- [Structured Logging](guide/logging.md) — observing lifecycle events with
  `cl-log-kit` via `*process-logger*`.
- [Results and Conditions](reference/results-and-conditions.md) — every
  accessor on `process-result`, `pipeline-result`, and the `process-error`
  hierarchy.
