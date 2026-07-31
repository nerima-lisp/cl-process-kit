## Summary

Describe the change in terms of user-visible behavior or contract impact.

## Validation

List the narrowest commands that demonstrate the change (`nix flake check` is
the authoritative gate -- see
[Development](https://github.com/nerima-lisp/cl-process-kit/blob/main/docs/src/development.md)).

## Public Surface Impact

Describe any change to `spawn`/`run`/`run-command`/`run-pipeline`/
`communicate`/`communicate-async`'s public `&key` surface or exported
conditions. Anything user-visible here belongs in the next release's
GitHub Release description.

## Follow-up Risk

Call out any remaining risk, unsupported platform, or intentional follow-up.
