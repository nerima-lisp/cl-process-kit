---
name: Bug report
about: Report a reproducible defect in cl-process-kit
title: "[bug] "
labels: ["bug"]
---

## Summary

Describe the failure in one or two sentences.

## Reproduction

List the smallest `spawn`/`run`/`communicate` call, test file, or ASDF system
that reproduces the issue. Note the platform (macOS/Linux) -- process-group
and signal-delivery semantics diverge between them, and that divergence is
this library's most common source of platform-specific defects.

## Expected Behavior

Describe the expected outcome.

## Actual Behavior

Describe the observed outcome, including error text or condition reports.

## Environment

SBCL version, OS/architecture, and whether this is under `nix flake check`
or a local `sbcl --script run-tests.lisp`.

## Security-Relevant?

If this involves argument/shell injection, process-group isolation, or
credential handling in `spawn-native`, see
[Security Considerations](https://github.com/nerima-lisp/cl-process-kit/blob/main/docs/src/reference/security-considerations.md)
and consider a private report instead: https://github.com/nerima-lisp/cl-process-kit/security/advisories/new
