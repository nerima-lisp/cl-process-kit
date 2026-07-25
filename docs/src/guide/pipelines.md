# Pipelines

```lisp
run-pipeline (commands &key input timeout grace-period cancellation-token
              on-timeout on-cancel max-output-characters) -> pipeline-result

run-pipeline/checked (commands &rest options) -> pipeline-result
```

`run-pipeline/checked` accepts the same options as `run-pipeline` and
signals `pipeline-exit-error` for the first unsuccessful stage.
`pipeline-success-p (pipeline-result)` reports whether every stage
succeeded without timeout or cancellation.

## Building a pipeline

`commands` must be a non-empty list of `command-spec` objects (see
[Command Specifications](command-specs.md)):

```lisp
(process-kit:run-pipeline
 (list (process-kit:make-command "/usr/bin/printf" (list "c\nb\na\n"))
       (process-kit:make-command "/usr/bin/sort" nil)))
;; => a PIPELINE-RESULT whose stdout is "a\nb\nc\n"
```

Pipeline wiring overrides the commands' stdin/stdout/stderr policies as
needed — you don't set `:stdout :pipe` yourself between stages.
Inter-stage pipes carry octets, so arbitrary binary data passes through the
pipeline without text decoding.

## Reading results

- The final stage's stdout is available through `pipeline-result-stdout`.
- Per-stage `process-result` objects are available through
  `pipeline-result-results`.
- `pipeline-result-stderr` contains each stage's captured stderr.
- `pipeline-result-timed-out-p`, `pipeline-result-cancelled-p`, and
  `pipeline-result-duration-seconds` report aggregate pipeline status.

## Failure diagnostics

`pipeline-exit-error` retains the full pipeline result, the zero-based
index of the first unsuccessful stage, and that stage's `process-result`.
Pipeline timeout and cancellation conditions retain the same diagnostic
context: their `result` readers refer to the actual affected stage, their
`stage-index` readers identify that stage, and their `pipeline-result`
readers retain every stage result. See
[Results and Conditions](../reference/results-and-conditions.md) for the
full condition hierarchy.
