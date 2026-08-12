# RC3 publication checklist

This checklist records readiness for `v1.0.0-rc.3` (native `1.0.0`, build `3`).
It does not authorize a commit, tag, push, visibility change, repository or
GitHub Release creation, upload, announcement, or binary distribution.

All final RC3 verification and artifact items remain unchecked until evidence
is produced from the exact clean candidate. Historical RC1 checks cannot be
carried forward as RC3 results.

## Recorded pre-seal evidence

The private RC3 candidate has completed these local pre-seal gates:

- complete native suite: 1,005 executed, 995 passed, 10 reviewed skips,
  0 failures;
- focused authority/restart/semantic gate: 8 of 8 passed;
- selected three-class Attached Data integration matrix: 60 of 60 passed;
- disposable application smoke: 41 of 41 passed, with cleanup complete;
- universal unsigned Debug build-for-testing and Release application: both
  passed for `arm64` and `x86_64`;
- exact-commit Node 22 build/test evidence: pending the committed fixture CI
  workflow because the local Node 26 runtime is unsupported; and
- release verifier: passed with a 905-method annotated RC1 baseline plus 100 new
  methods, for 1,005 current XCTest methods.

These results used no live-provider or remote-publication authority. They do
not check off the final identity- and artifact-bound items below: the commit,
annotated tag, clean public repository, source archive, SBOM, checksums, DMG,
signing, notarization, and publication are still pending.

## Identity and legal

- [x] Candidate metadata targets source/package `1.0.0-rc.3`, annotated tag
      `v1.0.0-rc.3`, release title **Agent Loki V1.0.0 Release Candidate 3**,
      and native `1.0.0` build `3`.
- [ ] Exact candidate commit and annotated-tag object recorded.
- [ ] Candidate index/worktree clean with unrelated state preserved.
- [ ] `LICENSE`, `NOTICE`, and `THIRD_PARTY_NOTICES.md` reviewed against the
      exact final tree.
- [ ] SPDX SBOM generated from the exact tag, parsed, reviewed, and its digest
      recorded.
- [ ] Maintainer completes the final source, dependency, artwork, trademark,
      rights, privacy, and notices review immediately before upload.

## Attached Data contract

- [x] Public docs distinguish **Link Read-Only** from **Import into Vault**,
      manual refresh from reimport, and **Detach** from **Remove Local Data**.
- [x] Public docs record complete-generation atomicity and preservation of the
      last accepted generation after cancellation or failure.
- [x] Public docs record local-model consent as opt-in/off by default and grant
      no remote-model, network, database, tool, write, or publication authority.
- [x] Public docs state exact SQLite/JSON admission boundaries, effective
      limits, accessibility behavior, privacy-safe diagnostics, and busy/WAL/
      stale-bookmark troubleshooting.
- [x] Unsupported NDJSON, SQLCipher, raw SQL, writes/migrations, remote
      databases/JSON, automatic refresh, live multiwriter sync, and BLOB-body
      indexing are explicit.
- [ ] Final UI copy, accessibility labels/hints, keyboard navigation,
      non-color-only state, error text, and documentation match are reviewed on
      the exact built app.

## Product and tests

- [ ] Focused Attached Data domain/persistence/file-authority tests pass.
- [ ] Focused SQLite tests pass, including exact header, read-only authorizer,
      coherent snapshot, busy/WAL, corruption/encryption classification,
      identity, budgets, BLOB exclusion, cancellation, and no partial import.
- [ ] Focused JSON tests pass, including UTF-8, duplicate keys, exact large
      numbers, JSON Pointer, stable IDs, budgets, malformed/trailing input,
      NDJSON rejection, cancellation, and no partial import.
- [ ] Controller/UI tests pass for Link, Import, manual refresh,
      reauthorization, detach, separate data removal, accessibility, status,
      browse/search, and preserved prior generation.
- [ ] Vault tests prove complete-generation atomic replacement, provenance,
      tombstones, revisions, semantic evidence, and rollback on failure.
- [ ] Local-model authority tests prove consent defaults off, remains
      source-scoped, and grants no remote-provider or write authority.
- [ ] Existing Slack, Discord, Support Email, Vault, Chat, model, update, and
      startup regressions pass.
- [ ] Complete native fixture suite passes with every skip reviewed.
- [ ] Disposable application smoke executes its complete named matrix with
      task-owned DerivedData/store roots; preflight alone is not a pass.
- [ ] Universal unsigned Debug-for-testing and Release builds pass for `arm64`
      and `x86_64`.
- [ ] Node 22 locked install, build, tests, and offline audit pass.
- [ ] Remote compatibility CI is recorded truthfully as passed, failed, or
      unrun; `READY_TO_RUN` is not a pass.

## Source, privacy, and documentation

- [ ] `scripts/verify-release.sh` passes on the clean tagged candidate.
- [ ] Secret/private-path/history classification passes without printing
      matched sensitive values.
- [ ] No tracked session logs, proof receipts, credentials, private paths,
      databases, model files, archives, DerivedData, or release output exist in
      the tagged tree.
- [ ] Synthetic fixtures contain no personal or live-provider data.
- [ ] README, architecture, connectors, Attached Data, privacy, security,
      support, changelog, roadmap, status, release notes, and releasing docs
      match the exact final implementation.
- [ ] Markdown links and static release-document checks pass in both the tagged
      tree and the extracted source archive.
- [ ] Optional live-provider smokes are either separately authorized and
      bounded or recorded as unrun; no missing credential is converted into a
      pass or failure.

## Clean publication repository and source artifacts

- [ ] After sealing the canonical RC3 tag, a fresh standalone repository is
      initialized on `main` from only the exact tagged tree, using the approved
      public author identity and no inherited `.git`, object store, or remote.
- [ ] `scripts/verify-publication-repo.sh` runs with the public author name and
      email, emits its deterministic preflight JSON in a separate directory,
      and proves exact canonical/public tag-tree equivalence plus exact public
      refs and object closure. The final artifact-root record remains absent
      for `prepare-github-release.sh` to regenerate.
- [ ] Every reachable commit, tag, tree, path, and blob is audited for secrets,
      private identity/path content, excluded proof/log content, deleted
      generated artifacts, gitlinks, replacement refs, and unreachable objects.
- [ ] `scripts/package-source-release.sh` produces
      `Agent-Loki-v1.0.0-rc.3-source.tar.gz` from the clean public repository's
      exact annotated tag.
- [ ] Extracted-tree verifier passes and the archive manifest/tree is
      independently compared with both accepted tagged trees; the embedded tar
      commit identifies the public tag commit.
- [ ] `scripts/generate-sbom.sh` produces
      `Agent-Loki-v1.0.0-rc.3-SBOM.spdx.json` offline from the public tag and
      binds its SPDX namespace to the public commit.
- [ ] `scripts/prepare-github-release.sh` creates and reproduces the one final
      `Agent-Loki-v1.0.0-rc.3-SHA256SUMS.txt`; the path was absent beforehand
      and every listed digest verifies.
- [ ] Exact commit, tag object, tree, archive, SBOM, checksum manifest, release
      notes, and verification-record identities are in the external packet.
- [ ] Configured remotes and repository visibility are reviewed immediately
      before the first authorized push.

## Binary status

The provisional classification is `BINARY_DISTRIBUTION_PENDING_SIGNING`. It is
not a final artifact result.

- [ ] Record exactly one final RC3 classification:
      `BINARY_DISTRIBUTION_READY`, `BINARY_DISTRIBUTION_PENDING_SIGNING`, or a
      precise `BINARY_DISTRIBUTION_BLOCKED_*` classification.
- [ ] If ready, universal app architecture, bundle/version/build, entitlements,
      Hardened Runtime, nested signatures, Developer ID identity, and Team ID
      pass on the exact app.
- [ ] If ready, the public DMG is Developer-ID-signed, Apple-notarized, stapled,
      `stapler`-validated, Gatekeeper-accepted, mounted read-only, and contains
      only the expected universal app and Applications link.
- [ ] If ready, signing, notarization, and DMG-verification JSON records agree
      with the immutable DMG digest.
- [ ] If ready, disposable install, first launch, upgrade, uninstall, and data
      preservation/removal evidence passes.
- [ ] No unsigned inspection DMG is included in public uploads.

## Local release manifest and publication

- [ ] `scripts/prepare-github-release.sh` revalidates all inputs and emits the
      machine-readable release manifest, reproduced checksums, publication
      repository verification into the previously absent final path, fail-fast
      local command plan, publication checklist, and non-upload publication
      packet.
- [ ] Manifest upload flags, media types, tag/tree identity, artifact digests,
      and binary classification are independently reviewed.
- [ ] The publication packet names every final upload, binds the checksum-file
      digest, and records successful checksum reproduction and entry checks.
- [ ] The operator plan uses OID-qualified refs, sets and verifies default
      branch `main`, records every required GitHub setting, and redownloads all
      release assets for exact name and SHA-256 verification.
- [ ] Release notes retain every pending/unrun/unsupported boundary and do not
      claim a test, tag, artifact, signing, notary, or publication result that
      did not occur.
- [ ] Explicit authorization is obtained for each remote operation.
- [ ] Only after every required gate passes: push clean public history/tag,
      create the release, upload reviewed artifacts, verify public digests and
      links, and record the resulting immutable identities.

Stop on any mismatch or missing evidence. The scripts prepare and verify local
state; they do not push, create a repository, create a release, or upload.
