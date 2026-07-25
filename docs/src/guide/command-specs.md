# Command Specifications

`make-command` creates an immutable-by-interface `command-spec`:

```lisp
(process-kit:make-command
 "/usr/bin/env" nil
 :search nil
 :environment-policy :inherit
 :environment-update (list (cons "LANG" "C")
                           (cons "DEBUG" nil))
 :directory #P"/tmp/"
 :stdin :inherit
 :stdout :capture
 :stderr :capture
 :result-type :string
 :external-format :utf-8
 :decoding-error-policy :replace)
```

Its positional arguments are `program` and a proper list of string
`arguments`.

## Environment

`environment-policy` is either `:inherit` or a complete list of
`"KEY=VALUE"` strings; an empty list requests an empty environment.
`environment-update` is an ordered alist: a string value sets a variable and
`nil` deletes it. Updates are applied after the base policy.

## Executable search

Executable search is disabled by default. With `search` (or `:search`)
true, `cl-process-kit` resolves the executable before launching it, using
only the `PATH` in the *effective* environment:

- `:inherit` therefore uses a copied parent `PATH` when present.
- A replacement environment without `PATH` performs no search and signals
  `process-launch-error`.
- Programs containing a slash bypass `PATH` lookup entirely.
- Relative programs and `PATH` components (including empty components) are
  resolved against the effective working directory.

!!! warning "Search failure modes"

    A candidate that is missing, is a directory, or is not executable
    signals `process-launch-error`.

## Stdio policies

The `stdin`, `stdout`, and `stderr` policies accept `:inherit`, `:null`,
`:pipe`, `:capture`, a stream, or a pathname; `stderr` additionally accepts
`:stdout`.

`result-type` is `:string` or `:octets`.

## Decoding errors

`decoding-error-policy` controls what happens when captured output isn't
valid text under `external-format`, and applies only when `result-type` is
`:string`. It is `:replace` by default: malformed byte sequences are
substituted with the Unicode replacement character, and for UTF-8 the
decoder holds back an incomplete multi-byte sequence at a read-buffer
boundary until the rest arrives rather than misreading it as invalid.
`:error` instead signals [`process-io-error`](../reference/results-and-conditions.md#condition-hierarchy)
the first time a malformed sequence is encountered. This option is shared
by [`run`/`communicate`](execution.md#options-shared-across-the-family) —
`make-command`'s `decoding-error-policy` is simply the `command-spec`-driven
way to set the same behavior for `run-command`.

## Accessors

Accessors are named `command-program`, `command-arguments`, `command-search`,
`command-environment-policy`, `command-environment-update`,
`command-directory`, `command-stdin`, `command-stdout`, `command-stderr`,
`command-result-type`, `command-external-format`, and
`command-decoding-error-policy`. `command-p` tests the type.

!!! danger "Untrusted input"

    Prefer `make-command` plus [`run-command`](execution.md) for untrusted
    data: arguments are passed directly without shell interpolation.
    `run-shell` invokes `/bin/sh -c`; never concatenate untrusted input into
    its command string.
