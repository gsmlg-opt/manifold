# ADR 0009: Exchange ActiveSync Connector

- **Status:** Accepted
- **Date:** 2026-08-06

## Context

ADR 0007 and 0008 cover Microsoft Graph and IMAP for provider import. Many
on-premises Exchange deployments expose mail over Exchange ActiveSync (EAS) with
Basic authentication and do not offer Graph or convenient IMAP. The `eas`
receive-method kind already existed as a `not_implemented` placeholder.

IMAP already supports bidirectional read-flag sync (`\\Seen`). EAS users need
the same Read import and write-back behavior.

## Decision

Extend `manifold_connectors` with `provider = "eas"`:

- Password credentials encrypted with the existing `Manifold.Connectors.Crypto`
  AES-GCM envelopes (`secret_kind = "password"`).
- Per-account EAS settings (`host`, `port`, `path` defaulting to
  `/Microsoft-Server-ActiveSync`, `username`, stable `device_id` /
  `device_type`, `protocol_version` defaulting to `14.1`, and `policy_key`
  after Provision).
- Basic Auth over HTTPS with TLS certificate verification on by default.
- Inbox **content** synchronization via Provision → FolderSync → Sync →
  ItemOperations Fetch (MIME) into `Ingest.import_external` with
  `source_kind = "provider_import"` (no delete/move/send write-back).
- **Read flags** are bidirectional:
  - Import `ApplicationData/Read` from Sync Add/Change into `remote_read` and
    local mailbox entries via `ApplyRemoteState`.
  - Local `Mail.mark_read/3` enqueues `PushRemoteRead`, which issues Sync
    `Change` with `Read` and advances the stored SyncKey.
- Test connection (discover Inbox) before persisting the account.

Autodiscover, NTLM/Kerberos, multi-folder sync, delete/move/send write-back,
Ping/push, contacts/calendar, and Office 365-specific ActiveSync remain out of
scope. Microsoft 365 cloud mail continues to use the existing Graph connector.

## Consequences

- New table `connector_eas_settings`.
- Sync branches on credential kind for password auth alongside IMAP.
- The add-receive-method flow gains an EAS form path (test then save).
- `enqueue_read_push` covers both `imap` and `eas` receive methods.
- Operators must keep `MANIFOLD_CONNECTOR_ENCRYPTION_KEY` configured; plaintext
  passwords must never be logged.
- On-prem Exchange must allow Basic Auth on the EAS virtual directory.
- Read write-back requires a valid collection SyncKey; failed pushes retry via
  Oban without blocking the local mailbox UI.
