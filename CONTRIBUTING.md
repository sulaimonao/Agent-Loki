# Contributing to Agent Loki

Thank you for helping improve Agent Loki. Contributions must preserve the
project's local-first, privacy-preserving, and fail-closed behavior.

## Before opening a change

1. Read `README.md`, `docs/ARCHITECTURE.md`, `docs/CONNECTORS.md`, and
   `SECURITY.md`.
2. Search existing issues before opening a new one.
3. Keep one change focused on one bounded objective.
4. Never use a real account, production store, personal message, credential,
   private attachment, or local proof artifact as a fixture.

For a suspected vulnerability, do not open a public issue. Follow
`SECURITY.md`.

## Development setup

Follow `docs/BUILDING.md` and `docs/TESTING.md`. Use the locked dependency
files. Do not update a dependency, lockfile, signing setting, entitlement, or
credential configuration as a side effect of unrelated work.

Ordinary tests must be fixture-only. Live provider checks require a separately
authorized disposable account and are never a prerequisite for a pull request.

## Change expectations

- Preserve unrelated worktree state.
- Prefer narrow, backward-compatible changes.
- Keep credentials in Keychain or ignored local configuration.
- Keep provider content out of logs, errors, snapshots, and test artifacts.
- Give connectors stable identity, provenance, cursor, lifecycle, and reason
  codes.
- Test success, failure, cancellation, retry, disconnect, deletion, and
  sensitive-field absence where applicable.
- Document behavior that changes user-visible privacy, networking, storage, or
  release expectations.

## Pull requests

A pull request should state:

- the objective and affected surfaces;
- privacy and security implications;
- tests actually run and their results;
- checks not run and why;
- any new dependency and its license;
- whether live accounts, signing, notarization, or network access were used.

Passing tests do not authorize publication or production activation.

## License

Unless explicitly marked otherwise, contributions intentionally submitted for
inclusion are licensed under Apache License 2.0 as described in `LICENSE`.
