# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Readability

- `src/communicate.lisp`: `communicate`'s cancellation watcher body -- a
  ~20-line anonymous lambda passed straight to `sb-thread:make-thread` --
  is now a named local function, `run-cancellation-watcher`, alongside its
  `labels` siblings (`finished-p`, `mark-cancelled`, etc.), so the thread
  creation call reads as `#'run-cancellation-watcher` instead of an
  unlabeled inline block. Extracted with `paredit-cli`.
- `src/spawn.lisp` and `src/command.lisp` each independently validated a
  `"KEY=VALUE"` environment-string entry (non-empty key before `=`,
  rejecting a duplicate key) with byte-for-byte identical logic under two
  different error-message labels. Extracted the shared shape into
  `%validate-environment-entry-shape` (`src/command.lisp`, next to
  `%validate-environment-entries`, its other caller) via
  `paredit refactor extract-function`; `spawn.lisp`'s
  `%validate-environment` now calls it with `"ENVIRONMENT"`, matching the
  uppercase label convention `%validate-environment-entries` already uses
  for `"ENVIRONMENT-POLICY"`/`"ENVIRONMENT-UPDATE"` (previously
  `spawn.lisp` alone used mixed-case "Environment" in its error text; no
  test asserted on the literal message, so this also fixes a real
  inconsistency, not just a duplication). Found via `paredit inspect
  similarity --threshold 0.85 src` (score 44.5, 46 shared AST nodes) rather
  than searched for. Net effect: fewer total expression/branch points to
  cover (4736/676 -> 4726/670), so `src/`'s coverage percentage rose
  slightly (87.5% -> 87.6% expression) as a side effect of having less
  duplicated code, not a coverage change pursued for its own sake.

### Testing

- `t/validation-test.lisp`'s `make-command`/`spawn-native` guard-clause
  tables now use `cl-weave:it-each` instead of a hand-rolled `dolist` over a
  list of `(label . thunk)` conses: every one of the 22 + 3 malformed-input
  rows is now its own independently-named, independently-reported test case
  (e.g. "rejects an empty program", "rejects a dotted (improper)
  :environment-update list") instead of one aggregate pass/fail that hid
  which row actually failed. Test count 152 -> 174; behavior and coverage
  unchanged, since it's the same guard clauses exercised the same way.
- Added `t/mutation-test.lisp`: `cl-weave:run-mutations` mutation-tests
  `process-success-p` and `pipeline-success-p` (`src/command.lisp`),
  systematically flipping their comparison/boolean logic and asserting the
  existing case battery notices every one-operator change
  (`cl-weave:assert-mutation-score` at a required 1.0 -- no surviving
  mutants). Coverage proves a line executed, not that a wrong result there
  would be caught; mutation testing closes that specific gap for these two
  pure predicates. Follows the exact pattern `nerima-lisp/cl-tty-kit`
  already established for this ecosystem (`contrib/weave-mutation-tests.lisp`):
  the `DEFUN` body is read live from `src/command.lisp` on every run (never
  copied into the test file), so there is nothing to fall out of sync with
  the real implementation.

### Dependencies

- Bumped `cl-weave` v0.11.0 -> v1.0.0, `cl-boundary-kit` v0.5.0 -> v0.6.0,
  `cl-log-kit` v1.1.0 -> v1.6.0, `cl-tty-kit` v0.5.0 -> v0.6.0. Checked each
  upstream changelog/diff for breaking changes before bumping: none touch
  the surface this library actually calls (`cl-boundary-kit`'s v0.6.0
  unbounded-wait-by-default change is scoped to its own
  `process-boundary-run`/`process-kit-run-fn`, which this library never
  calls; `cl-log-kit`'s "logger as explicit first argument" breaking change
  landed at v1.0.0 and `%log` (`src/logging.lisp`) already passed it
  explicitly). Verified with a full `nix flake check` (`checkout-tests`
  152/152 at 87.5%/79.9% coverage, `pty-tests` 6/6), not just a local
  `sbcl --script` run.
- `flake.nix`'s four nerima-lisp inputs are consumed purely as raw ASDF
  source trees (`buildASDFSystem` `src`, or `CL_SOURCE_REGISTRY` at
  runtime) -- none of their own flake `packages`/`checks` outputs are ever
  used. `cl-weave`, `cl-boundary-kit`, and `cl-log-kit` were still declared
  as full flakes (missing `flake = false`, unlike the already-correct
  `cl-tty-kit`), so `nix flake update` pulled in their entire transitive
  dev-only input graphs (`treefmt-nix`, `cl-json-kit`, and `cl-json-kit`'s
  own sub-inputs) into this project's `flake.lock` for no reason. Added
  `flake = false` to all three, shrinking `flake.lock` from 34 nodes to 6.
- `cl-tty-kit` v0.6.0 vendors `nerima-lisp/cl-prolog` as a git submodule
  (`vendor/cl-prolog`) and self-registers that path from its own `.asd`;
  a plain `github:` fetch does not follow submodules (regardless of a
  `?submodules=1` query string, which only the `git+https://` fetcher
  honors), so the Nix sandbox had an empty `vendor/cl-prolog` and
  `cl-process-kit/pty-test` failed to load with `Component #:CL-PROLOG not
  found, required by #<SYSTEM "cl-tty-kit">`. This only broke inside `nix
  flake check`'s sandboxed `pty-tests`, not local `sbcl --script` runs
  against a manually-cloned `~/ghq` checkout that already had the
  submodule populated -- another case (see the `[0.2.0]` entry below) of a
  local run passing while the authoritative sandboxed check does not.
  Fixed by switching `cl-tty-kit`'s input to
  `git+https://github.com/nerima-lisp/cl-tty-kit?ref=refs/tags/v0.6.0&submodules=1`.

## [0.2.0]

### Added

- Published a MkDocs Material documentation site (installation,
  execution/async/pipeline/PTY guides, and a results-and-conditions
  reference) to GitHub Pages, built `--strict` so broken links or
  unlisted pages fail the build. See `docs/src/` and `nix build .#docs`.

### Dependencies

- Bumped `cl-weave` v0.10.0 -> v0.11.0, `cl-boundary-kit` v0.4.0 -> v0.5.0,
  `cl-tty-kit` v0.4.0 -> v0.5.0 (`cl-log-kit` was already at latest,
  v1.1.0). Verified with a full `nix flake check` (both `checkout-tests`
  and `pty-tests`), not just a local `sbcl --script` run.
- `cl-boundary-kit` v0.5.0 added its own new dependency on `cl-log-kit`;
  `flake.nix`'s `clBoundaryKit` package derivation now passes it as a
  `lispLibs` input, or `nix build .#cl-process-kit` fails with `Component
  :CL-LOG-KIT not found` (`nix flake check`'s `checkout-tests` didn't
  catch this, since it points ASDF at every input's source directly
  rather than going through `buildASDFSystem`'s Nix-tracked dependency
  graph).
- Fixed `t/native-spawn-test.sh`'s Darwin file-mode check, which had never
  actually passed under `nix flake check` on macOS: a Nix sandbox's `PATH`
  puts GNU coreutils' `stat` ahead of the system's, and GNU `stat -f`
  means "show filesystem status" (a different, incompatible option from
  BSD `stat -f FORMAT`), so `stat -f %Lp` silently invoked the wrong
  implementation and failed. Now calls `/usr/bin/stat` explicitly on that
  branch. Confirmed pre-existing (reproduced against the previously
  committed `flake.lock`, unrelated to the dependency bump above) via a
  clean `nix flake check` run before any other change in this session.

### Performance

- `spawn`/`run` accept a new `:fd-limit` option. `SB-EXT:RUN-PROGRAM`'s
  forked child closes every inherited file descriptor up to its
  `RLIMIT_NOFILE` one syscall at a time on Darwin; on a host with a very
  large ambient limit (routine under Nix/direnv shells), that is a
  measurable fraction of per-call latency. `:fd-limit` temporarily lowers
  this process's own soft limit around the spawn (restored immediately
  afterward, regardless of success or failure) so the child inherits a
  smaller one instead. Opt-in and `NIL` by default: the lowered limit is
  inherited by the child through `exec` and persists for its lifetime, so
  this is a caller decision, not a silent default.
- Copier/feeder read-write chunk size raised from a 4 KiB page to 64 KiB;
  `SB-SPROF` showed this dominating large-transfer wall time.
- `run-tests.lisp` now enforces a coverage ratchet: it fails the run if
  `src/` expression or branch coverage regresses below the best level
  previously reached, both locally and in `nix flake check`'s
  `checkout-tests`.

## [0.1.0]

First release. The initial `sb-ext:run-program`-only prototype was rebuilt
into a full process execution toolkit on top of `cl-boundary-kit` and
`cl-log-kit`; nothing prior to this was ever tagged, so there is no
compatibility surface to preserve.

### Known Limitations

- On Linux, when a spawned process exits but leaves a backgrounded
  descendant holding its stdout/stderr pipe open (e.g. `sh -c "sleep 5 &
  exit 0"`), `run`'s output-draining cleanup can block past
  `drain-timeout-seconds` instead of returning within its documented
  bound. The cleanup path force-closes the blocked stream to unstick its
  reader thread, which reliably interrupts a concurrent blocking `read`
  on macOS/BSD but is not guaranteed to on Linux: the reader only
  returns once the pipe's last writer actually exits or closes its own
  copy of the descriptor. Fixing this correctly needs the copier read
  loop redesigned around non-blocking I/O instead of relying on `close`
  to interrupt a blocked read; tracked for a future release. The
  regression test for this case is skipped on Linux
  (`t/run-test.lisp`) rather than flaking CI red on every run.
- Several more process-group/communicate tests are Linux-only flaky for the
  same underlying reason -- timing around signal delivery, process-group
  reaping, and blocked-read interruption is not guaranteed identical to
  macOS/BSD: `communicate result caching > rejects a concurrent communicate
  while capture is in progress`; `process-group termination > kills
  descendants after the process-group leader exits on TERM`, `> does not
  publicly signal a group after its leader is terminal`, `> provides
  distinct leader and group signal operations`, `> close-process cleans
  descendants more than five seconds after their leader exits`
  (`t/spawn-test.lisp`); and `communicate-async events > communicate-async
  reports overflow without losing the terminal event`, `> cancels blocked
  asynchronous output without failing the task` (`t/async-task-test.lisp`).
  All are skipped on Linux for the same reason and tracked alongside the
  drain-timeout issue above for a future release.

### Added

- `run` (and `run/checked`, `run-shell`) gained an `:output` policy alongside
  the existing `:error` one, and both now accept `:inherit` or a stream in
  addition to `:capture` (and, for `:error`, `:output`). `:capture` collects the
  fd into the `process-result` as before (still the default, so existing callers
  are unaffected); `:inherit` lets the child write straight to this process's own
  descriptor for live, uncaptured output; and a stream sends it there. This lets
  a caller run a foreground command with output flowing live to the terminal (or
  a log file) while still getting `run`'s timeout and whole-process-group
  SIGTERM→SIGKILL escalation — the "stream it, don't buffer it" case that
  previously forced callers back onto raw `spawn`/`communicate`. The
  command-spec path (`make-command`/`run-command`) already accepted inherited and
  stream stdio; this brings the program-and-args `run` path to parity.
- `command-spec`/`make-command`: validated, defensively-copied command
  construction (`:search`, `:environment-policy`, `:environment-update`,
  `:directory`, `:stdin`/`:stdout`/`:stderr`, `:result-type`,
  `:external-format`, `:decoding-error-policy`).
- A `process-error` condition hierarchy (launch, exit, timeout,
  cancellation, pipeline, communicate-mismatch, group-isolation, and I/O
  failures) built on a shared `define-process-condition` macro.
- `process-kit:run`/`run-command` (synchronous, timeout-aware,
  output-capturing) and `process-kit:spawn` (asynchronous primitive), now
  built on a mutex-guarded process handle and POSIX process-group
  isolation instead of calling `sb-ext:run-program` directly.
- An async task/event API (`async-events.lisp`, `async-task.lisp`):
  `communicate-async` delivers `process-event`s instead of blocking for a
  final `process-result`, with a cursor API (`next-process-event`) over
  bounded, retained event history.
- Pipeline composition (`run-pipeline`/`run-pipeline/checked`): chains
  commands with each stage's stdout feeding the next stage's stdin, and
  attributes a mid-pipeline timeout or cancellation to the failing stage
  via `process-timeout-error`'s `stage-index`/`pipeline-result` slots.
- An optional native (non-`sb-ext:run-program`) spawn backend
  (`native-spawn.lisp` plus a `posix_spawn`-based C trampoline in
  `native/spawn.c`) with typed launch-failure phases and errno reporting.
- An optional native PTY backend (`cl-process-kit/pty`,
  `cl-process-kit/pty-test`): a controlling-terminal session with its own
  foreground process group, kept out of the dependency-light core system.
- Structured logging of process lifecycle events via `*process-logger*`
  (spawned/launch-failed/timed-out/cancelled), backed by `cl-log-kit`.
- Injectable `clock`/`sleeper` boundaries from `cl-boundary-kit` for
  deterministic polling in tests.
- Process-group isolation so a timeout kill reaches descendants spawned by
  the child (e.g. a shell running an external command), not just the
  immediate child process; spawn now verifies the child actually landed in
  its own process group and signals `process-group-isolation-error` on
  mismatch instead of continuing silently.
- Test suite (`cl-process-kit/test`) using `cl-weave`, covering all of the
  above plus UTF-8 decoding edge cases, at-most-once communicate
  semantics, copier thread error propagation, and property-based checks
  over the run/octet/success-predicate value space; a separate
  `cl-process-kit/pty-test` integration suite for the PTY backend.
- Nix flake (`flake.nix`) building the native C trampoline and PTY shared
  library, with package, dev shell, and `nix flake check` test targets;
  GitHub Actions CI running `nix flake check`.

### Changed

- `process-timeout-error`'s `timeout-seconds` slot is renamed to `timeout`
  and gains `result`/`stage-index`/`pipeline-result` slots for
  pipeline-stage attribution.
- The default SIGTERM-to-SIGKILL grace period changed from 0.2s to 1.0s.
- `run`/`spawn` reject `:input t`, since standard input inheritance cannot
  be safely isolated into the child's process group.
- `cl-process-kit` now depends on `cl-boundary-kit` and `cl-log-kit`
  instead of being dependency-free.
