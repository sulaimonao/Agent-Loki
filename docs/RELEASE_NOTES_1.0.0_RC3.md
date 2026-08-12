# Agent Loki V1.0.0 Release Candidate 3

- Source version/tag: `1.0.0-rc.3` / `v1.0.0-rc.3`.
- Native application: version `1.0.0`, build `3`.
- Status: prerelease.

RC3 is the privacy-clean successor to the unpublished RC2 candidate. It keeps
the local-first Loki Brief application and the bounded Attached Data Sources
work while removing maintainer-specific source configuration, personal test
fixtures, and placeholders for private projects.

## Privacy and portability changes

- Public source attribution uses the neutral `Agent Loki contributors` label.
- The clean public repository is generated with neutral commit and tag metadata;
  private development history is never published.
- Owner-specific Apple Team IDs, certificate fingerprints, Slack application
  IDs, and update-signing public keys are absent from tracked defaults.
- Developers supply signing, Slack, and update values through ignored local
  configuration or explicit release-command inputs.
- The downloadable DMG is intentionally built without a maintainer-specific
  Slack Client ID. Slack remains available to source builders who configure
  their own public desktop-app Client ID.
- Private project/provider placeholders and their UI catalog entries are not
  part of this candidate.

Apple's Developer ID signature necessarily exposes the legal signing identity
and Team ID in the distributed binary. Those values authenticate the DMG and
are not stored as source configuration.

## Included product surfaces

- Universal macOS application for Apple Silicon and Intel.
- Local-first briefs, Vault storage, scheduling, and Agent Loki Chat.
- Optional fixed-loopback Ollama models; deterministic behavior works without
  Ollama or a cloud account.
- Read-only Slack support when a source builder supplies a compatible public
  Client ID.
- Bounded, read-only native Discord history ingestion.
- Credential-free local `.eml` and `.mbox` Support Email import.
- User-selected SQLite and JSON Attached Data Sources with bounded preview,
  **Link Read-Only** and **Import into Vault** modes, manual refresh,
  provenance, cancellation, detach, and separate local-data removal.

## Security and data boundaries

- Tests and release smoke use synthetic fixtures and do not contact live
  Slack, Discord, email, or Ollama services.
- Credentials stay in Keychain or ignored local configuration.
- Telemetry, analytics, remote logging, and cloud-model fallback are absent.
- Attached SQLite is opened through a separate read-only connection and never
  attached to the production Vault connection.
- Attached JSON is parsed as bounded inert RFC 8259 data. URL-like, script-like,
  and reference-looking strings are not fetched or executed.
- No model may author arbitrary SQL or grant itself source, network, tool,
  publication, or write authority.

## Known limitations

- Support Email does not include Maildir, IMAP, provider OAuth, SMTP, or
  outbound mail.
- Native Discord is read-only; posting, reactions, moderation, and webhooks are
  excluded.
- The prebuilt DMG does not include operator-specific Slack or update-feed
  configuration.
- Scheduling requires the app to remain running.
- Vault content and user-created exports are not application-level encrypted.
- Attached Data does not support SQLCipher, arbitrary SQL, writes, remote
  databases, remote JSON references, automatic refresh, or live multiwriter
  synchronization.

Install by opening the signed and notarized DMG, dragging **LokiBrief.app** to
Applications, and launching the copied app. Verify downloaded assets against
the accompanying `SHA256SUMS` file.

For installation and usage help, see [Support](../SUPPORT.md). Report suspected
vulnerabilities privately through the process in [Security](../SECURITY.md);
do not include secrets or personal data in a public issue.
