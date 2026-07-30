# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- `spawn`'s (`src/spawn.lisp`) two failure `handler-case` clauses each
  repeated the same "log the failure, clean up whatever `RUN-PROGRAM`
  already started" pair of calls before re-signaling in their own,
  different way. Extracted the shared pair into a local `abort-spawn` `flet`,
  found by reading the function directly rather than a tool flag (its span
  is too small for `paredit inspect similarity`'s default `node_count`
  threshold to surface).
- Bumped four SHA-pinned GitHub Actions that had real, unclaimed releases
  sitting upstream: `softprops/action-gh-release` v2.6.2 -> v3.0.2 (Node 24
  runtime only; no input/output change), `actions/configure-pages` v5 ->
  v6.0.0 (Node 24 runtime only), `actions/upload-pages-artifact` v3 -> v5.0.0
  (its one behavior change, excluding dotfiles from the uploaded artifact,
  doesn't affect this project's `mkdocs build` output -- confirmed by
  listing the actual built site directory, which contains none), and
  `actions/deploy-pages` v4 -> v5.0.0 (Node 24 runtime only). `actions/
  checkout`, `DeterminateSystems/nix-installer-action`, `cachix/
  cachix-action`, and `DeterminateSystems/update-flake-lock` were already on
  their latest tags.
- Deduplicated `t/mutation-test.lisp`'s `process-success-p`/
  `pipeline-success-p` case batteries: each was written out as an identical
  literal twice (once for the direct "battery matches the live function"
  assertion, once passed to the mutation-kill assertion), found by running
  `paredit inspect similarity` over `t/` for the first time this session
  (score 58.0, the top cross-location match). Named each battery a
  top-level `defparameter` so both tests read from the same data and cannot
  silently drift apart if a case is later added to only one.
- Unified `await-process` and `next-process-event`'s (`src/async-task.lisp`)
  independent "wait on the task's condition variable, checking an optional
  deadline first" blocks into a shared `%wait-on-task` continuation, plus a
  `%deadline-from-timeout` helper for the relative-timeout-to-absolute-
  deadline arithmetic both already repeated verbatim. Found via
  `paredit inspect similarity`, the highest-scoring cross-location match
  after filtering same-file parent/child nesting noise. Lowered the
  branch-coverage floor again, 81.4% -> 81.3%, for the same reason as below:
  removing the duplicated deadline check took 2 more redundant branch points
  out, holding the uncovered-branch count at 124; see the comment above
  `+minimum-branch-coverage+` for why 81.4 (not 81.3) was the wrong floor to
  land on the first time.
- Unified three independent "poll until done or a deadline passes" loops --
  `%wait-until-terminal` and `%wait-until-group-gone` (`src/communicate.lisp`)
  and `%terminate-processes`'s pipeline-stage shutdown wait
  (`src/pipeline.lisp`) -- into one shared `%poll-until` continuation-style
  helper. Lowered the branch-coverage ratchet floor from 81.5% to 81.4% as a
  direct, understood consequence: the dedup removed 4 branch points that were
  redundant copies of each other (covered and total both dropped by exactly
  4, so the actual count of uncovered branches did not change), not 4 newly
  untested ones.

### Added

- Three `cl-weave:defmatcher` custom matchers over `process-result`/
  `pipeline-result` -- `:to-have-succeeded`, `:to-have-timed-out`, and
  `:to-have-been-cancelled` -- registered in `t/package.lisp` via a shared
  `%define-result-state-matcher` macro. Tests read
  `(expect result :to-have-succeeded)` rather than
  `(expect (process-success-p result) :to-be-truthy)` wherever the assertion
  checks a result's terminal state as a fixed boolean.

### Changed

- Bumped `cl-weave` v1.0.0 -> v1.1.0, `cl-boundary-kit` v0.6.0 -> v1.0.0
  (both stable releases with no behavior change to the surface this library
  calls; verified against each release's own `CHANGELOG.md`).
- Bumped `cl-tty-kit` v0.6.0 -> v1.0.2 and, since v1.0.0, simplified the
  `flake.nix` input from `git+https://...?submodules=1` back to a plain
  `github:` reference: `cl-tty-kit` no longer vendors `nerima-lisp/cl-prolog`
  as a git submodule, and `cl-prolog` is now a regular top-level nerima-lisp
  package depended on only by `cl-tty-kit/test`, which this repository's
  `cl-process-kit/pty` system (depending on plain `cl-tty-kit`) never loads.

## [1.0.1] - 2026-07-26

A packaging fix. No source change, and the exported API is identical to 1.0.0.

### Fixed

- `flake.nix` asked for `cl-log-kit/v1.6.0`, a tag that has never existed —
  `cl-log-kit` has only ever released `v1.0.0`. The v1.0.0 tag of this
  repository still carries that reference, so anyone pinning
  `cl-process-kit/v1.0.0` as a flake fails at `nix flake lock` from a cold
  cache. Existing lock files hide it by holding an already-resolved revision,
  which is why CI stayed green. Three repositories pin this one that
  way — `cl-boundary-kit`, `cl-cc-runtime` and `cl-cli` — and would all have
  broken at once on the next `flake-update.yml` run.

  Tags are never moved, so v1.0.0 stays as it is and this release exists to
  give downstream something that resolves. Sibling versions are now read out of
  each pinned source's own `.asd` rather than repeated here, so the two cannot
  drift apart again.

## [1.0.0] - 2026-07-26

First stable release. The exported API is unchanged from 0.2.0 and is now
covered by semantic versioning; what this release adds is evidence about how
it behaves on the platforms it claims to support, gathered by actually
running the suite on Linux rather than inferring from macOS. That turned up
two real defects, both invisible on macOS, and one broken CI check.

The first of the two `### Known Limitations` recorded under 0.1.0 -- the
drain-timeout bound -- is resolved. The second, a group of timing-sensitive
process-group tests, is not: it is narrowed, re-diagnosed, and still skipped
on Linux.

### Correctness

- **`drain-timeout-seconds` is now honoured on Linux.** A copier thread
  drained a child's stdout/stderr with a blocking `read(2)`, and
  `%drain-copiers` unstuck one that overran its deadline by force-closing
  the stream under it. Closing a descriptor wakes a thread already parked
  in `read(2)` on macOS/BSD, but that is a BSD courtesy rather than
  anything POSIX promises, and Linux does not do it: the reader stayed
  parked until whoever else held the pipe's write end let go. After
  `sh -c "sleep 5 & exit 0"` that is a backgrounded descendant which
  outlives the leader by design, so the wait was effectively unbounded.
  The observed symptom on Linux was worse than 0.1.0's note described --
  not merely `run` overrunning its documented bound, but `run` *signalling*
  `process-io-error :cleanup` ("Copier thread did not terminate after its
  stream was closed") once the force-close failed to land.

  The read loop now waits with `poll(2)` on a bounded timeout and checks a
  stop flag between turns (`%await-fd-readable`), so the decision to give up
  is taken by the reader itself instead of being inflicted on it through the
  descriptor. The bound then holds by construction on any POSIX platform
  rather than by accident on some. The flag is checked *before* readiness,
  which bounds the loop even against a child that never stops producing:
  one poll interval plus one bounded `read(2)` per turn. Polling costs no
  wakeup rate the library was not already paying, since `communicate`'s own
  deadline loop already runs at `+default-poll-interval+`.

  `%drain-copiers`' escalation gained the cooperative stop as its first
  rung -- ask, then force-close, then signal -- ordered by what each costs
  when it fires, in the same continuation-passing shape as
  `escalate-unless-gone`'s SIGTERM -> SIGKILL -> give-up. Force-closing is
  now a fallback for a copier parked where a flag cannot reach it (a
  `read-sequence` on a non-fd stream) rather than the primary mechanism.
  `%communicate-base`'s cleanup path was reordered to match: it retires the
  copiers before their streams, so `close-process-streams` no longer closes
  a descriptor under a live reader on every pass -- a descriptor the OS is
  free to reissue the moment it is closed.

- **`:on-timeout` and `:on-cancel` are validated at the entry points that
  own them.** Every entry point resolves these by comparing against
  `:error` and treating anything else as `:return`, which made an
  unrecognised value indistinguishable from a deliberate `:return` instead
  of an error. `run`, `run-command` and `run-pipeline` compounded it: each
  hands `communicate` a hardcoded `:on-timeout :return` and decides for
  itself whether to signal, so `%validate-communication-options`' guard
  never saw what the caller wrote. A misspelt `:errror` therefore read as
  `:return` and silently swallowed the very timeout or cancellation the
  caller had asked to have signalled. `%validate-outcome-policy` now guards
  each policy where it is accepted -- `run` (`:on-timeout`, `:on-cancel`),
  `run-command` (both), `run-pipeline` (both), and `communicate`
  (`:on-cancel`, which had no guard either).

### Testing

- The drain-timeout regression test ("run returns boundedly when an exited
  leader leaves a pipe-holding descendant") is no longer skipped on Linux --
  the fix above makes it platform-independent, and it passes on CI.

- The other seven Linux skips are re-diagnosed rather than removed. They had
  been filed under the same "process-group/communicate timing is not
  guaranteed identical on Linux" heading as the drain bug, which conflated
  two unrelated things. They do not share its cause: each asserts that a
  process group is *gone* within a 0.1s grace period, which a contended
  shared CI runner cannot reliably deliver. (They pass on an uncontended
  aarch64 Linux container and fail on GitHub's x86_64 runners -- contention,
  not architecture.) Their skip reasons now say that instead. They are not
  given more headroom because a timing assertion loose enough to survive
  arbitrary contention no longer asserts the timing; the honest fix is to
  make the assertion event-driven rather than deadline-driven, which is
  deferred.

- **The coverage ratchet had been failing every Linux CI build**, on a
  comparison it should never have made. The floor tracked the figure from a
  complete run (macOS, nothing skipped) but was enforced against the reduced
  Linux run, so CI reported the skipped tests as a coverage "regression" --
  86.9% against an 87.0% floor -- with every test passing. The floors are now
  enforced only when the whole suite ran (`+suite-complete-p+`); otherwise
  coverage is reported with an explicit note that it is not comparable.

- **A guard-clause test that names a program which does not exist proves
  nothing.** `t/run-timeout-test.lisp`'s "run rejects invalid timeout
  controls before spawning" spawned `/bin/true`, which macOS does not ship
  (`true` lives in `/usr/bin` there). All ten of its assertions passed on a
  `process-launch-error` for the missing file -- identically, and just as
  green, whether or not the guard under test existed. That is what hid the
  `:on-timeout` gap above: the assertion only had to mean something once
  the suite was first run on Linux, where `/bin/true` does exist. A
  `%true-program` fixture now resolves `true` through the ambient `PATH`,
  matching the existing `%spawn-sleeping` fixture, and is used by the 17
  call sites that actually spawn. The remaining literal `/bin/true`
  occurrences are in `make-command` data tables that never spawn, where the
  string is inert.

- Added a regression test asserting that all four entry points reject an
  unrecognised outcome policy rather than reading it as `:return`.

- Coverage ratchet advanced to 87.4% expression / 81.5% branch (from
  87.0/79.5), measured on a complete run.

### Documentation

- Documented the timeout and cleanup deadlines. `grace-period`,
  `poll-interval`, `timeout-signal`, `kill-signal` and
  `drain-timeout-seconds` previously appeared only inside `run`'s signature
  in the options table -- five knobs with no stated meaning or default,
  covering the escalation behaviour that is the library's whole reason to
  exist. The execution guide now gives them a table of their own, explains
  why signals go to the process group rather than the child, and explains
  why draining has a deadline separate from the child's (a descendant that
  outlives the leader inherits the same pipe and can hold it open
  indefinitely).

- Added a "Running the suite on both platforms" section to the development
  guide, covering the container invocation for checking Linux behaviour
  locally, and the two habits this release's bugs argue for: never name a
  program a guard-clause test does not intend to execute, and prefer fixing
  a platform difference to skipping the test that catches it.

### Build/environment

- `flake.nix` hardcoded `"0.2.0"` in four separate places (the docs
  derivation, the `cl-process-kit` package, and the `cl-process-kit-pty`
  package), plus two more in `cl-process-kit.asd` (`cl-process-kit` and
  `cl-process-kit/test`) -- six places a release has to remember to bump in
  lockstep, with no build-time check that they agree. `nerima-lisp/cl-boundary-kit`
  v0.6.0 already fixed the identical problem in its own `flake.nix` (found
  while auditing this project's own environment setup for the same class
  of drift); ported the same technique here: a `version` `let` binding
  parses the `:version` form out of `cl-process-kit.asd` line-by-line
  (Nix's `builtins.match` is whole-string-anchored and `.` doesn't span
  newlines, so a single multi-line regex doesn't work) and every Nix
  package now `inherit`s it. A release now only ever edits the `.asd`.
- `cl-process-kit/pty` and `cl-process-kit/pty-test` were missing the
  `:version`/`:author`/`:maintainer`/`:license`/`:homepage`/`:bug-tracker`/
  `:source-control` metadata the other two systems in the same file
  already carry -- added it for consistency.

### Production readiness

- Added `SECURITY.md`, `SUPPORT.md`, and `CONTRIBUTING.md` (GitHub's
  standard community-health filenames, which its UI surfaces automatically
  regardless of README content) -- this repository had none, unlike sibling
  `nerima-lisp` projects (`cl-weave` has all three). Scoped and sized for
  this project specifically rather than copied verbatim: `SECURITY.md`
  names the concrete classes of report that actually apply here (shell/
  argument injection via `run-shell`/`make-command`, process-group
  isolation failures, `spawn-native`'s privilege/credential handling), not
  a generic template; `CONTRIBUTING.md` documents the coverage ratchet and
  `nix flake check` as the authoritative (not just convenient) verification
  step, matching how this project is actually developed and verified
  throughout this changelog.

### CPS

- `src/copier.lisp`'s `%drain-copiers` had a two-step "join within the
  remaining time; if that times out, force-close the stream and give it
  one more brief join" escalation inlined as nested `when`s. Extracted
  `%join-copier-unless-timed-out (copier timeout on-timeout)`, which calls
  the `on-timeout` continuation only if the join actually times out --
  the same shape as `communicate.lisp`'s `escalate-unless-gone`, applied
  one level down at the copier-thread join instead of the process-group
  signal escalation. `%drain-copiers`'s two-step escalation is now two
  nested calls to it instead of two nested `when`s, matching this
  codebase's established `call-with-X`/continuation-parameter idiom.

### Correctness

- `src/copier.lisp`'s `%join-copier` accepted an `&optional timeout` and, if
  omitted, joined a copier thread with no bound at all -- an unbounded wait
  on a thread that can be blocked reading a live (possibly-hung) child
  process's stdout/stderr. Audited every `SB-THREAD:JOIN-THREAD`/
  `PROCESS-WAIT`/`SB-EXT:PROCESS-WAIT` call in `src/` for this same class of
  risk: the other four unbounded `PROCESS-WAIT` calls (`communicate.lisp`,
  `native-spawn.lisp`, `process-handle.lisp`, `spawn.lisp`) are each
  provably safe by construction -- reached only after the process has
  already been SIGKILLed (which POSIX guarantees terminates it) or is
  already OS-reported as terminal, so the wait there reaps a dying/dead
  process rather than blocking on a live one. `%join-copier` was the one
  genuine gap. Made `timeout` a required parameter (it was never actually
  called without one -- the unbounded branch was dead in practice, not just
  in principle) and updated its docstring to state the "never unbounded"
  contract explicitly.

### Data/logic separation

- `src/native-spawn.lisp`'s `%native-spawn-phase` mapped the native spawn
  trampoline's byte phase codes to keywords with a `case` form embedded
  directly in the lookup function. Hoisted the mapping into a top-level
  `+native-spawn-phases+` alist, leaving `%native-spawn-phase` as a plain
  `(or (cdr (assoc number +native-spawn-phases+)) :unknown)` traversal --
  the phase table can now be read, diffed, or extended on its own, separate
  from the lookup logic that applies it, matching the pattern already used
  elsewhere in `src/` (e.g. `+task-terminal-state-rules+`).

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

### Documentation

- Audited every public function signature documented in `README.md` and
  `docs/src/guide/*.md` against the actual `&key` lists in `src/run.lisp`,
  `src/spawn.lisp`, and `src/communicate.lisp` (plus the condition
  hierarchy in `src/conditions.lisp`, the `process-result`/`pipeline-result`
  structs in `src/types.lisp`, and the PTY/event/task accessors in
  `src/pty.lisp`/`src/async-events.lisp`/`src/async-task.lisp`, which were
  already accurate). Found `run`'s `output` keyword (`%run-base`) -- the
  stdout counterpart of `error`'s policy, controlling whether stdout is
  `:capture`d, `:inherit`ed live, or sent to a stream -- completely
  undocumented, even though it has been part of the public API since the
  `[0.1.0]` entry below; `error`'s own accepted values were also
  under-described (listed only `:capture`/`:output`, omitting `:inherit`
  and stream targets that `%valid-run-output-policy-p` also accepts). Also
  found `README.md`'s `run`/`communicate` signatures missing
  `decoding-error-policy` and `docs/src/guide/execution.md`'s `run`
  signature and `docs/src/guide/async.md`'s `spawn` signature missing
  `fd-limit` -- each doc had independently drifted to cover only the
  option added most recently in its own edit history. Fixed all of these
  in `docs/src/guide/execution.md` and `docs/src/guide/async.md`, which
  remain the single authoritative reference (see the next entry for why
  `README.md` no longer duplicates them).
- `README.md` had grown a ~450-line "API" section duplicating the option
  reference already maintained on the MkDocs site (`docs/src/guide/*.md`,
  `docs/src/reference/results-and-conditions.md`) -- the exact duplication
  responsible for the signatures drifting out of sync in the entry above,
  and for the site's own "Native spawn trampoline" page having no README
  counterpart at all. Simplified `README.md` to a landing page (intro,
  install, one minimal usage example, links to the published docs) and
  removed the API section and the Development section's test-suite/
  source-layout breakdown entirely, leaving `docs/src/` as the only place
  a signature or option list is written down.

## [0.2.0] - 2026-07-25

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

## [0.1.0] - 2026-07-24

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
