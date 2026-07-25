# Security Policy

## Supported Versions

Security fixes are applied to the current mainline release. Earlier releases
are not supported; upgrade to the latest release before reporting a behavior
that may already be fixed.

## Reporting a Vulnerability

Do not open a public issue for a suspected vulnerability. Report it through
[GitHub private security advisories](https://github.com/nerima-lisp/cl-process-kit/security/advisories/new).

Include a minimal reproduction, affected version or commit, impact, and any
suggested mitigation. Avoid publishing exploit details until a maintainer has
coordinated disclosure with affected users.

## Response and Disclosure

Maintainers aim to acknowledge a report within seven calendar days, validate
the issue, and coordinate a fix or mitigation with the reporter. Do not
publish vulnerability details before a coordinated disclosure date is agreed.

## Scope

`cl-process-kit` launches external processes and constructs their argument
lists, environment, and working directory from caller-supplied data.
Security-sensitive reports include:

- Shell/argument injection in `run-shell` or the `make-command`/`run-command`
  path (arguments are passed directly to `exec`, never through a shell, so a
  report showing untrusted data reaching a shell unintentionally is in scope).
- Process-group isolation failures that leave descendants unterminated after
  a timeout or cancellation, or that signal the wrong process group.
- Privilege- or credential-handling defects in `spawn-native`'s `uid`/`gid`/
  `groups`/`resource-limits` support (`native/spawn.c`).
- Resource-limit or file-descriptor handling that could leak sensitive
  descriptors into a spawned child.

Reports about the correctness of arbitrary shell commands passed to
`run-shell` by design (it is documented as `/bin/sh -c`, equivalent to
`system()`) are not security issues in this library.
