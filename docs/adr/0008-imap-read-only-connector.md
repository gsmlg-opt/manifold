# ADR 0008: Read-Only IMAP Account Connector

- **Status:** Accepted
- **Date:** 2026-08-05

## Context

ADR 0007 introduced read-only Gmail and Microsoft Graph connectors so Manifold
could import provider-hosted mail without becoming those providers' metadata
source of truth. Many users still keep mail on arbitrary IMAP servers (self-hosted
Dovecot, Fastmail, university accounts, etc.) that do not offer OAuth.

ADR 0007 deferred IMAP. Without an IMAP path, the empty-state "add account"
wizard could only connect the two OAuth providers, leaving a large class of
mailboxes unsupported.

## Decision

Extend `manifold_connectors` with `provider = "imap"`:

- Password credentials encrypted with the existing `Manifold.Connectors.Crypto`
  AES-GCM envelopes (`secret_kind = "password"`).
- Per-account IMAP settings (`host`, `port`, `tls_mode` in `{ssl, starttls}`,
  `username`, `mailbox_path` defaulting to `INBOX`).
- TLS certificate verification on by default.
- Auto-create a local domain + mailbox from the email address; the UI never
  asks for a domain.
- Read-only INBOX synchronization via UID SEARCH / UID FETCH RFC822 into
  `Ingest.import_external` with `source_kind = "provider_import"`.
- Bidirectional `\\Seen` synchronization: inbound FLAGS sync plus local
  mark-read/unread write-back via `UID STORE ±FLAGS (\\Seen)`.
- Test connection before persisting the account.

At acceptance, POP3, JMAP, multi-folder sync, and per-account SMTP send were out
of scope. ADR 0010 later superseded the SMTP portion by implementing
account-selected authenticated SMTP; POP3, JMAP, and multi-folder IMAP sync remain
out of scope.
Provider write-back beyond IMAP `\\Seen` remains out of scope.

## Consequences

- New table `connector_imap_settings` and expanded `connector_credentials`
  (`secret_kind`, `password_ciphertext`, nullable refresh token for password
  secrets).
- Sync branches on credential kind: OAuth refresh vs decrypted IMAP password.
- The add-account wizard gains an IMAP form path that skips mailbox selection.
- Operators must keep `MANIFOLD_CONNECTOR_ENCRYPTION_KEY` configured; plaintext
  passwords must never be logged.
- Future work may add STARTTLS-only hosts, additional folders, or OAuth-for-IMAP
  without changing the read-only import boundary.
