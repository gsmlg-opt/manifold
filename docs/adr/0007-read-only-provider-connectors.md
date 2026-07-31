# ADR 0007: Read-Only Provider Mailbox Connectors

- **Status:** Accepted and implemented (OAuth revised 2026-07-31)
- **Date:** 2026-07-29
- **Revised:** 2026-07-31 — prefer OAuth Device Authorization Grant

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

Operators want connector registration to work as a **public client** when the
provider allows it: typically only a `client_id`, without shipping a
`client_secret` in self-hosted config—the same operator burden as connecting
Gmail or Outlook in a desktop mail client. Authorization-code redirects with
PKCE also force registering loopback/production redirect URIs and matching
Endpoint URL configuration. Manifold does **not** use IMAP/XOAUTH2 as the sync
channel (see Rejected Alternatives); the public-client OAuth model is what
aligns with Apple Mail-style setup.

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

- OAuth token acquisition (device code and/or authorization code) and refresh.
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

**Preferred grant:** OAuth 2.0 Device Authorization Grant (RFC 8628). The UI
shows `user_code` and `verification_uri`, then polls the token endpoint until
the user finishes consent on another device. `client_secret` is optional: a
provider is enabled when a non-empty `client_id` and the required endpoint URLs
are present.

**Microsoft 365:** Uses device flow with a public-client app registration
(“Allow public client flows”). Device and token endpoints are:

```text
https://login.microsoftonline.com/<tenant>/oauth2/v2.0/devicecode
https://login.microsoftonline.com/<tenant>/oauth2/v2.0/token
```

**Gmail / Google:** Google’s documented device-flow **allowed scope list does
not include Gmail API scopes** (only OpenID Sign-In, limited Drive, and
YouTube). Requesting `gmail.readonly` via device flow is not a supported
platform path. Therefore Gmail keeps the **authorization code + PKCE `S256`**
path with a redirect callback. Prefer a Google OAuth client type that can
operate as a public client (Desktop / installed) so `client_secret` may be
omitted; a Web client secret remains optional in Manifold config when present.

One-time OAuth transactions store a hashed public state token. Device-flow
transactions encrypt the provider `device_code`; authorization-code transactions
encrypt the PKCE verifier and persist the exact redirect URI for callback
comparison. Access and refresh tokens use versioned AES-256-GCM envelopes.
Production requires a stable Base64-encoded 32-byte encryption key.

Gmail callback paths remain:

```text
https://<PHX_HOST>/connectors/gmail/callback
```

(local development: `http://localhost:4290/connectors/gmail/callback`).

Microsoft no longer requires a redirect URI for connection. Phoenix controllers
retain Gmail start/callback only. Device authorization is driven from the
Add Account LiveView.

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
- Device flow removes Microsoft redirect-URI registration for self-hosted
  public clients.

### Negative

- Pull synchronization has provider-dependent delay and API quota cost.
- A local copy may temporarily lag provider folder/read/star state.
- OAuth client registration and encryption-key lifecycle add operator work.
- Provider deletion does not reclaim local raw storage automatically.
- Polling introduces up to five minutes of scheduling delay before new account
  work is recreated.
- Gmail still needs a redirect URI and cannot use Google’s device grant for
  mailbox scopes until Google expands the allowed device-flow scope list.

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

### Force Google device flow for Gmail scopes

Rejected. Google documents that the limited-input / device OAuth flow supports
only a fixed allowlist that excludes Gmail API scopes. Pretending otherwise
would fail at Google’s authorization server.

### Reuse Apple Mail (or other vendor) OAuth client credentials

Rejected. Apple Mail’s OAuth client is Apple’s registered public/native app;
embedding or configuring that `client_id` in Manifold violates provider terms
of service, and redirect URIs / device registration will not match. Operators
must register their own public Desktop (Google) or public Entra (Microsoft)
application. Manifold aligns with Apple Mail only on the **user experience
model** (public-client OAuth consent without requiring a shipped secret), not
on IMAP/XOAUTH2 transport or third-party client IDs.
