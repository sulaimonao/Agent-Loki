# Support

## Public support routes

- Use GitHub Discussions for usage questions and community help when
  Discussions is enabled for the public repository.
- Use the bug-report issue template for reproducible product, connector, build,
  or documentation problems.
- Use the connector-request template for a new provider or local format. Do not
  attach provider exports or account identifiers.
- Use the feature-request template for other product proposals.
- Use the private route in `SECURITY.md` for vulnerabilities or reports that
  contain security- or privacy-sensitive context. Never place vulnerability
  detail in a public issue.

No public support email address is configured. The single future configuration
point is the repository/release variable `LOKI_PUBLIC_SUPPORT_EMAIL`; it must
remain unset until the maintainer approves a public address. Never infer an
address from Git metadata or commit history.

## Include

- Agent Loki or Loki Brief version and build;
- macOS and Xcode versions when relevant;
- the affected feature;
- steps using synthetic or redacted data;
- the consumer-visible error and bounded reason code; and
- whether the issue reproduces with optional providers disabled.

For Attached Data, also include the displayed format, mode (Link or Import),
collection/JSON Pointer, operation, reason code, and whether the source is busy,
uses WAL, was moved/replaced, or requested reauthorization. Use a small
synthetic database or JSON document if a reproduction is necessary.

## Never include

Do not post tokens, authorization codes, cookies, private keys, certificates,
provisioning profiles, Keychain data, message or email bodies, channel or
mailbox names, private URLs, prompts, database files, exports, attachments,
screenshots containing personal data, or absolute private filesystem paths.
Do not post security-scoped bookmark data, SQLite sidecars, JSON contents, raw
database rows, schema details from private data, or model context derived from
an attached source.

## Current limitations

- Native Discord and Support Email are accepted source-candidate features;
  credentialed live-provider smokes were not run.
- IMAP and outbound email are not implemented.
- Live provider smokes are not part of ordinary support diagnostics.
- Binary distribution and a production update host are not currently
  available.
- Provider-specific login help for Gmail, Microsoft, Discord user accounts,
  self-bots, SMTP, and other unsupported authentication modes is out of scope;
  requests should describe the desired read-only outcome, not provide a real
  credential.
- Attached Data is limited to bounded local SQLite 3 and single-document JSON.
  NDJSON, SQLCipher, raw SQL, writes, remote databases/JSON, automatic refresh,
  live multiwriter sync, and BLOB-body indexing are unsupported.
- Link refresh is manual. A busy writer, unavailable WAL/SHM sidecar, or stale
  bookmark may require closing the writer, keeping its sidecars together, or
  reauthorizing the file. Failed refresh preserves the last accepted
  generation. Imported snapshots must be reimported to reflect file changes.
- Final RC3 test, tag, artifact, signing, notarization, and publication results
  are pending; do not report RC1 evidence as an RC3 result.

## Response expectations

Agent Loki is maintained as a small open-source project. Response and repair
times are best-effort; no support SLA, guaranteed response window, emergency
on-call service, data-recovery service, or provider-account administration is
offered. Maintainers may ask for a smaller synthetic reproduction or close a
report that cannot be investigated without private data.
