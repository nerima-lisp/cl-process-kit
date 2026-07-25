# Structured Logging

Bind `*process-logger*` to a `cl-log-kit` logger (see
[`cl-log-kit`](https://github.com/nerima-lisp/cl-log-kit)'s
`log-kit:make-logger`) to observe process launch outcomes, timeout/
cancellation signal escalation, and pipeline stage failures as structured
log records:

```lisp
(let ((process-kit:*process-logger*
        (log-kit:make-logger :name "my-app" :handler (make-instance 'log-kit:json-handler))))
  (process-kit:run "sleep" (list "10") :timeout 1))
```

`*process-logger*` defaults to `nil`, which keeps the library silent exactly
as before observability was added.

!!! warning "Binding scope and the cancellation watcher thread"

    Most lifecycle records — launch outcomes, timeout escalation, pipeline
    stage failure — are emitted on the calling thread, so a thread-local
    `let` binding of `*process-logger*` observes them.

    The *cancellation* escalation record, however, is emitted from an
    internal watcher thread, and an SBCL thread reads a special variable's
    **global** value rather than the spawning thread's dynamic binding. To
    observe every record, including cancellation escalation, install the
    logger globally:

    ```lisp
    (setf process-kit:*process-logger* logger)
    ```

    rather than binding it dynamically around a single call.
