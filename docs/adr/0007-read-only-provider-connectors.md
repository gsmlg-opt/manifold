# ADR 0007: Read-Only Provider Mailbox Connectors

- **Status:** Accepted and implemented
- **Date:** 2026-07-29

## Context

Manifold is a self-hosted webmail application intended to replace desktop mail
clients. Locally hosted domains arrive through SMTP or the optional cloud edge,
but users also need to read mail held by Gmail and Microsoft 365.

Provider mailboxes differ from SMTP ingress:

- There is no SMTP peer, HELO, envelope sender, or observed `RCPT TO`.
- Provider message and cursor identities are required for resumable pull.
- OAuth credentials are long-lived secrets.
- Provider APIs expose state through labels, folders, deltas, and tombstones.
- Provider raw RFC message bytes must remain the source for local projection.

Reusing SMTP-shaped metadata for provider imports would create false audit data.
Writing provider results directly into parsed Mail schemas would bypass the
spool, immutable raw store, acceptance transaction, and recovery model.

## Decision

Add `manifold_connectors` as a read-only provider synchronization application:

```text
manifold_connectors
  -> manifold_core
   + manifold_data
   + manifold_accounts
   + manifold_ingest
   + manifold_mail

manifold_web
  -> public APIs from manifold_connectors
```

The Web application uses only the public Connectors context.

### Provider boundary

Implement a normalized provider behaviour for:

- OAuth code exchange and token refresh.
- Provider account identity.
- Initial synchronization cursors.
- One bounded synchronization page.
- Exact raw RFC message retrieval.

The first adapters are Gmail and Microsoft Graph. They request read-only scopes:

```text
Gmail:     openid email https://www.googleapis.com/auth/gmail.readonly
Microsoft: openid profile offline_access User.Read Mail.Read
```

The connector does not request Gmail modify/send scopes or Microsoft
`Mail.ReadWrite`/`Mail.Send`. It does not mutate provider mailboxes or send
through either provider.

### OAuth and secrets

OAuth uses authorization code plus PKCE `S256`. State is random, stored only as
a SHA-256 digest, expires, and is consumed once under a PostgreSQL row lock.
The exact redirect URI is persisted and compared on callback.

PKCE verifiers, access tokens, and refresh tokens use versioned AES-256-GCM
envelopes. Associated data binds each envelope to its provider transaction or
account and credential purpose. Production requires a stable Base64-encoded
32-byte encryption key.

The intended callback paths are:

```text
https://<PHX_HOST>/connectors/gmail/callback
https://<PHX_HOST>/connectors/microsoft/callback
```

Phoenix controllers derive these active callback routes from the configured
Endpoint URL. Production runtime configuration requires a valid connector
encryption key and enables each provider only when its client ID and secret are
both present.

Gmail uses the OpenID UserInfo `sub` as its durable provider account ID. The
provider email is mutable display metadata. Once connected, a provider account
identity remains bound to its original active local mailbox.

### Durable import boundary

Provider raw messages enter through `Manifold.Ingest.import_external/3`.
`manifold_ingest` owns the provider identity to inbound-delivery mapping and
commits the following in one transaction:

- Inbound delivery with `source_kind = provider_import`.
- Initial mailbox entry for the configured local mailbox.
- Accepted lifecycle event.
- Raw archival Oban job.
- External ingress identity and accepted fingerprints.

The spool reaches `ready/` before this transaction. The external identity is
unique by provider, connector account, and provider message ID. Matching retries
return the existing receipt; conflicting raw or target fingerprints fail.

Provider imports do not create `DeliveryRecipient` rows and do not fabricate:

- SMTP peer IP.
- HELO.
- Envelope sender.
- Original envelope recipients.

Normal raw archival, MIME projection, security, and mailbox presentation then
operate on the imported delivery. A separate idempotent worker applies
supported provider folder, read, starred, and deleted state after projection.
Remote deletion moves the local entry to trash and never deletes immutable raw
data.

### Cursor and recovery boundary

Gmail uses a mailbox-wide initial scan followed by `historyId` updates.
Microsoft Graph uses folder discovery plus one message-delta lane per folder and
requests immutable message IDs. Graph continuation URLs are opaque but may be
followed only when they retain the configured HTTPS authority.

A cursor advances only after every actionable message in the page has crossed
the durable local acceptance boundary. Mapping and state application are
idempotent. Gmail history expiry and Graph delta expiry reset to
non-destructive reconciliation.

The first sync job is inserted transactionally when authorization completes. A
five-minute Oban cron job recreates missing sync work for eligible accounts.
Provider push notifications are deliberately not part of this milestone.

## Consequences

### Positive

- External mail uses the same immutable raw source and crash recovery model as
  SMTP and edge ingress.
- Audit data distinguishes SMTP transactions from provider imports.
- Provider API and OAuth behavior remain isolated behind a replaceable
  application boundary.
- Cursor replay cannot create duplicate local deliveries for the same provider
  identity.
- Read-only scopes limit the effect of a compromised connector credential.

### Negative

- Pull synchronization has provider-dependent delay and API quota cost.
- A local copy may temporarily lag provider folder/read/star state.
- OAuth client registration and encryption-key lifecycle add operator work.
- Provider deletion does not reclaim local raw storage automatically.
- Polling introduces up to five minutes of scheduling delay before new account
  work is recreated.

## Rejected Alternatives

### Treat provider import as SMTP

Rejected because it would invent transport facts and corrupt the audit model.

### Write directly to parsed message tables

Rejected because it bypasses durable spool acceptance, immutable raw storage,
and reprocessing.

### Use IMAP as the first connector

Rejected for this milestone. Provider APIs offer stronger stable identities,
delta cursors, OAuth integration, and exact raw retrieval for the two selected
providers.

### Add provider send at the same boundary

Rejected. Read synchronization and outbound submission have different scopes,
idempotency, and failure semantics. Outbound remains owned by
`manifold_outbound` and managed provider adapters. Manifold never performs
direct recipient-MX delivery.

### Depend on push notifications

Rejected for Milestone 6. Push requires public callback lifecycle, renewal,
replay protection, and provider-specific operational state. Initial
synchronization is pull-based; push may later be an optimization, never the
only durable trigger.
