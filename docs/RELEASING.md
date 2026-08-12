# Releasing

## Current candidate and release planes

RC3 targets source tag `v1.0.0-rc.3` and release title **Agent Loki V1.0.0
Release Candidate 3**. The native bundle is version `1.0.0`, build `3`; the RC
suffix belongs to source/tag/release metadata.

The **source release** is an unsigned, sanitized snapshot of the accepted tree.
The **binary release** is a separately signed, notarized, stapled, packaged,
and validated application. Source acceptance must never claim binary readiness.

RC3 private pre-seal native tests, builds, disposable smoke, and release
verifier passed. Exact-commit Node 22 verification is delegated to the
committed fixture CI workflow because the local Node 26 runtime is unsupported.
The exact commit and annotated tag, source archive,
SBOM, checksums, DMG, signing, notarization, stapling, Gatekeeper validation,
clean-publication-repository audit, and publication remain pending. The
historical RC1 results do not substitute for the new RC3 evidence.

## Release-tool invariants

The release scripts:

- use `set -euo pipefail` and require explicit inputs;
- derive `1.0.0-rc.3` from an annotated `v1.0.0-rc.3` tag instead of accepting
  an independent version string;
- require the tag commit to equal `HEAD` and refuse a dirty candidate;
- reconcile package and native version/build metadata;
- require absolute task-owned artifact paths and refuse unexpected existing
  outputs;
- use deterministic `Agent-Loki-v1.0.0-rc.3-*` artifact names;
- keep credentials and private absolute paths out of tracked output; and
- provide dry-run command planning without building, signing, notarizing,
  mounting, pushing, uploading, creating a repository, or creating a release.

No release script installs dependencies. `prepare-github-release.sh` writes a
local machine-readable manifest and publication command plan only; an operator
must separately review and execute any remote action under explicit authority.

## Exact-candidate verification

Start from the intended annotated tag at a clean `HEAD`. Keep live-provider
opt-ins and credentials unset unless a separately authorized disposable smoke
requires them.

1. Run `scripts/verify-release.sh` without `--allow-dirty`.
2. Run the focused Attached Data tests and complete native fixture suite in a
   fresh DerivedData directory outside the repository.
3. Build unsigned universal Debug-for-testing and Release configurations.
4. Run `scripts/run-disposable-app-smoke.sh`; preflight alone is not a smoke
   result.
5. Run the locked Node build/test with a supported Node 22 toolchain. When one
   is not installed locally, require the exact-commit fixture CI result and do
   not substitute Node 26.
6. Review privacy/secret/private-path classification, documentation links,
   dependency licenses, notices, accessibility evidence, and every skip.
7. Record remote CI truthfully as passed, failed, or unrun. Do not convert
   `READY_TO_RUN` into a pass.

The completed private pre-seal runs recorded:

- complete native suite: 1,005 executed, 995 passed, 10 reviewed skips, and
  0 failures;
- focused authority/restart/semantic gate: 8 of 8 passed;
- selected three-class Attached Data integration matrix: 60 of 60 passed;
- disposable application smoke: 41 of 41 named tests passed and task-owned
  cleanup completed;
- universal unsigned Debug build-for-testing and default Release application:
  both passed for `arm64` and `x86_64`;
- exact-commit Node 22 build/test: pending the committed fixture CI workflow;
  and
- pre-seal release verifier: passed with 905 annotated RC1 baseline XCTest
  methods plus 100 additions, for 1,005 current methods.

These passes used no live provider, remote Git operation, or publication
authority. They must not be represented as final commit-, tag-, repository-, or
artifact-bound evidence until those pending identities exist.

## Publication repository and source artifacts

The private development repository contains excluded local proof artifacts in
reachable ancestry. Do not change its visibility or publish its refs or tags.

After sealing the canonical RC3 tag, export that exact tagged tree without its
`.git` directory into a fresh sibling directory. Initialize a standalone
repository on `main` with an approved public author identity, create the clean
root publication commit and annotated `v1.0.0-rc.3` tag, and add no remote.
Tracked bytes must match the canonical tagged tree exactly.

Before creating source artifacts, verify the clean repository from either of
the two repositories being compared:

```sh
scripts/verify-publication-repo.sh \
  --tag v1.0.0-rc.3 \
  --canonical-repo /absolute/private/canonical-repo \
  --publication-repo /absolute/task-owned/clean-publication-repo \
  --publication-author-name 'PUBLIC NAME' \
  --publication-author-email public@example.com \
  --output /absolute/task-owned/preflight/Agent-Loki-v1.0.0-rc.3-PUBLICATION_REPO_VERIFICATION.json
```

The verifier requires clean canonical and publication trees, no publication
remote, a standalone object database, exact `main` and tag refs, bounded clean
history, matching tag trees, and no extra refs, reflogs, unreachable objects,
gitlinks, forbidden historical paths, secrets, or private content. It scans
every reachable commit, tag, tree, path, and blob and emits a machine-readable
local record. Use a separate preflight directory for this first record. Keep
the final artifact-root `PUBLICATION_REPO_VERIFICATION.json` path absent:
`prepare-github-release.sh` reruns the verifier and owns that final output.

From that exact one-commit publication checkout, also run its explicit local
release gate:

```sh
scripts/verify-release.sh --public-clean-history
```

This mode never substitutes for the canonical verifier's RC1 comparison; the
publication-repository verifier binds the two independently verified trees.

Run the packager and SBOM generator from the clean publication repository's
exact tag, not from the private-history repository:

```sh
scripts/package-source-release.sh \
  --output-dir /absolute/task-owned/artifacts \
  --tag v1.0.0-rc.3

scripts/generate-sbom.sh \
  --tag v1.0.0-rc.3 \
  --artifact-root /absolute/task-owned/artifacts
```

The source packager uses the public tag commit, deterministic gzip metadata,
forbidden-path checks, extraction into a task-owned directory, and the
extracted-tree release verifier. Independently reproduce the tar stream from
the public tag, compare its embedded commit and tree with both repositories,
and parse the SPDX 2.3 document. Do not run `generate-checksums.sh` here:
`prepare-github-release.sh` owns the one final checksum file, requires that
path to be absent, and reproduces and verifies every entry after the manifest
is final.

The source inputs produced at this stage are:

- `Agent-Loki-v1.0.0-rc.3-source.tar.gz`; and
- `Agent-Loki-v1.0.0-rc.3-SBOM.spdx.json`.

Generation of the clean public repository and RC3 artifacts remains pending.
Review every reachable object and configured remote again immediately before
the first separately authorized push.

## Binary procedure

Binary preparation is optional and independent. It requires an explicitly
approved Developer ID Application identity, expected Team ID, and existing
notarytool Keychain profile. The signer also requires an explicit local path to
an app-specific Developer ID provisioning profile whose Team, application ID,
certificate, expiration, and all-devices distribution scope are validated
before it is embedded. Keep the source profile outside the repository and
artifact root. Never place credentials, private keys, or notarization secrets
in arguments, tracked files, or release manifests.

The bounded sequence is:

1. `build-release-app.sh` creates the universal Release archive.
2. `sign-release-app.sh` copies the app, validates and embeds the app-specific
   Developer ID provisioning profile, signs it, verifies the Team ID,
   entitlements, hardened runtime, nested code, version/build, bundle ID,
   profile authorization, and `arm64` plus `x86_64`, then emits a local signing
   JSON record. That detailed record is not a public upload.
3. `create-dmg.sh` creates and Developer-ID-signs the deterministic public DMG.
4. `notarize-dmg.sh` submits that DMG with an explicitly named existing
   Keychain profile, requires Apple's `Accepted` result, staples and validates
   the ticket, runs the DMG verifier, and emits notarization JSON.
5. `verify-dmg.sh` independently requires the DMG signature, stapled ticket,
   Gatekeeper acceptance, read-only mount, expected top-level contents, and a
   signed universal `LokiBrief.app` with the expected Team ID.
6. Complete disposable install, first launch, upgrade, uninstall, and
   data-preservation checks on the immutable artifact.

The public binary name is
`Agent-Loki-v1.0.0-rc.3-macOS-universal.dmg`. An unsigned inspection artifact,
if separately produced, must be named and treated as
`UNSIGNED-NOT-FOR-PUBLIC-DISTRIBUTION`; it must never be uploaded as a public
binary.

The provisional status is `BINARY_DISTRIBUTION_PENDING_SIGNING`. Final status
remains pending fresh exact-artifact evidence.

## Local publication manifest

After the public-tag source archive and SBOM, release notes, human-readable
verification record, and schema-valid candidate verification record exist,
run the following command from the clean canonical repository. Supply exactly
one truthful binary status. A ready binary status also requires the exact DMG
plus signing, notarization, DMG-verification, and disposable install-smoke
records whose digests agree.

```sh
scripts/prepare-github-release.sh \
  --tag v1.0.0-rc.3 \
  --artifact-root /absolute/task-owned/artifacts \
  --canonical-repo /absolute/private/canonical-repo \
  --publication-repo /absolute/task-owned/clean-publication-repo \
  --publication-author-name 'PUBLIC NAME' \
  --publication-author-email public@example.com \
  --github-repository OWNER/REPOSITORY \
  --source-archive /absolute/task-owned/artifacts/Agent-Loki-v1.0.0-rc.3-source.tar.gz \
  --sbom /absolute/task-owned/artifacts/Agent-Loki-v1.0.0-rc.3-SBOM.spdx.json \
  --release-notes /absolute/task-owned/artifacts/Agent-Loki-v1.0.0-rc.3-RELEASE_NOTES.md \
  --verification /absolute/task-owned/artifacts/Agent-Loki-v1.0.0-rc.3-VERIFICATION.md \
  --candidate-verification-record /absolute/task-owned/artifacts/Agent-Loki-v1.0.0-rc.3-CANDIDATE_VERIFICATION.json \
  --binary-status BINARY_DISTRIBUTION_PENDING_SIGNING
```

The script revalidates the inputs and writes:

- `Agent-Loki-v1.0.0-rc.3-PUBLICATION_REPO_VERIFICATION.json`;
- `Agent-Loki-v1.0.0-rc.3-RELEASE_MANIFEST.json`;
- `Agent-Loki-v1.0.0-rc.3-SHA256SUMS.txt`;
- `Agent-Loki-v1.0.0-rc.3-GITHUB_PUBLICATION_DRY_RUN.txt`;
- `Agent-Loki-v1.0.0-rc.3-GITHUB_PUBLICATION_CHECKLIST.md`; and
- `Agent-Loki-v1.0.0-rc.3-PUBLICATION_PACKET.json`.

The manifest records artifact names, media types, digests, upload eligibility,
canonical and public commit/tree/tag-object identities, repository identity,
and binary classification. The final SHA256SUMS covers every upload other than
itself; the local non-upload publication packet binds its digest, exact upload
inventory, and successful checksum reproduction. Generated operator commands
fail fast, push OID-qualified refs, set and verify `main`, and redownload every
asset for exact digest verification. These files contain no secret and execute
no remote operation. Their generation and review are pending.

## Stop conditions

Stop before publication on a dirty or wrong-tag tree; failed or skipped required
test; version/build mismatch; secret-like value; private path; proof artifact;
unexpected generated file; unresolved dependency license; archive/tree/digest
mismatch; inaccessible WAL-consistent Attached Data evidence; unsigned,
unstapled, unnotarized, or Gatekeeper-rejected public DMG; unaudited publication
history; or missing human rights/privacy review.

Do not weaken a failed gate, reuse RC1 evidence, publish a private ref, or treat
a dry-run as execution.

## Startup failure classification

Explicit signed-smoke admission remains isolated and fail-closed. Ordinary
production-store open failure preserves the original store and returns a
temporary in-memory unavailable state. Invalid injected isolation intent or
failure to construct any model remains terminal. The private RC3 pre-seal suite
and 41-test disposable smoke exercised these boundaries successfully, but that
evidence is not yet bound to the pending final commit and annotated tag.
