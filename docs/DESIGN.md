# Manifold

## Product and Architecture Design

- **Status:** Milestones 0-6 implemented
- **Product type:** Self-hosted provider mail client with local mail, contacts, and calendars
- **Primary deployment model:** Self-hosted main OTP release, with an optional separate ingress edge
- **Primary user interface:** Phoenix LiveView in a web browser
- **Outbound model:** Account-selected Gmail API, Microsoft Graph, or authenticated SMTP submission; no direct recipient-MX delivery

For the current implementation status and remaining tasks, start with
[PROGRESS.md](PROGRESS.md). [README.md](README.md) indexes current guides and
historical plans. Release 0.1 requirements and milestone completion evidence
below retain their historical scope; they are not current acceptance results.

---

## 1. Product Definition

Manifold is a self-hosted web email application for receiving, reading, organizing,
composing, and sending email. Its browser interface is the primary mail client and
is intended to replace desktop clients such as Microsoft Outlook and Apple Mail
for configured provider mailboxes. The main release imports mail from Gmail,
Microsoft Graph, IMAP, and EAS into local Manifold mailboxes. Gmail and Graph
receive synchronization does not mutate remote mailboxes; IMAP and EAS also
support read-state writeback. Account-selected delivery submits through Gmail API,
Microsoft Graph, or an authenticated SMTP relay without turning Manifold into a
direct-MX MTA.

The product combines the user-facing webmail experience with an Elixir-native
mail platform. Its optional `manifold_edge` release accepts SMTP deliveries for
configured domains, validates recipients during the SMTP transaction, and
durably spools mail before acknowledgement. The main release pulls edge mail
through the signed import protocol; it does not include an inbound SMTP listener.
All receive paths preserve the original RFC 5322 message and process it
asynchronously into mailbox-oriented views. Account-owned contacts synchronize
with iCloud. Independent local calendars can synchronize with Google and iCloud
simultaneously through separate target bindings.

Outbound mail is delegated to the Account's Gmail, Graph, or authenticated SMTP
method. Manifold owns composition, local queueing, immutable submission
snapshots, and provider acceptance state, but does not operate a public outbound
MTA or perform direct MX delivery. Resend and its webhooks remain a legacy path;
other managed-provider adapters are future extension points.

Manifold is not intended to reproduce Postfix, Dovecot, and Rspamd in its first
release. The implementation is inbound-first because durable receipt is the
foundation of a trustworthy email client, but the product surface is a complete
Phoenix webmail application rather than an SMTP administration console.

### Product statement

> Manifold is a self-hosted webmail application that replaces a desktop email
> client for configured mail providers, backed by durable local Elixir/OTP mail
> infrastructure, account-selected sending, and optional cloud SMTP ingress.

---

## 2. Release 0.1 Goals

Release 0.1 must provide the following capabilities:

1. Receive Internet email over SMTP on TCP port 25.
2. Support `EHLO`/`HELO`, `MAIL FROM`, `RCPT TO`, `DATA`, `RSET`, `NOOP`, `QUIT`, and opportunistic STARTTLS.
3. Validate domains and recipients during `RCPT TO`.
4. Reject unknown recipients before accepting message data.
5. Preserve accepted message data as an immutable raw `.eml` object.
6. Return SMTP `250` only after the message has crossed a durable local acceptance boundary.
7. Continue archival and processing after process or node restarts.
8. Support domains, mailboxes, aliases, and plus addressing.
9. Store authoritative metadata in PostgreSQL.
10. Store raw messages and attachments through a storage behaviour, with local filesystem and S3-compatible/ESS implementations.
11. Provide a Phoenix LiveView webmail interface for inbox, message, mailbox, and administration workflows.
12. Expose stable context APIs so other applications can use Manifold without scraping the UI.
13. Submit outbound messages through a paid provider adapter.
14. Receive and persist provider delivery, bounce, and complaint webhooks.
15. Provide structured logs, Telemetry events, audit events, and operational health information.

---

## 3. Explicit Non-Goals for Release 0.1

The first release will not implement:

- Direct outbound MX delivery.
- Public outbound IP reputation management.
- IMAP.
- POP3.
- JMAP.
- Sieve.
- Full calendar or contact support.
- A complete anti-spam engine.
- A complete antivirus engine.
- Gmail or Microsoft 365 mailbox mutation, including Microsoft draft creation.
- Native desktop or mobile applications.
- An IMAP backend intended for Outlook, Apple Mail, or other desktop clients.
- Multi-region or active-active clustering.
- A standalone cloud SMTP relay.
- End-user rules comparable to mature hosted mail providers.
- Hard deduplication based only on `Message-ID` or body hashes.
- Internationalized SMTP envelope addresses through `SMTPUTF8`.

These were Release 0.1 boundaries, not architectural dead ends. Milestones 0-4
form the Release 0.1 local mailbox core. Milestone 5 adds the optional cloud
ingress edge. Milestone 6 implements read-only Gmail and Microsoft 365 receive
connectors. Gmail API, Microsoft Graph direct MIME send, and authenticated SMTP
submission are account-selected outbound capabilities; IMAP server access,
POP3, JMAP, and provider mailbox mutation remain out of scope.

---

## 4. Architectural Principles

### 4.1 Webmail product, inbound-first implementation

The browser application is Manifold's primary email client. The target user
experience includes inbox navigation, message reading, search, mailbox state,
attachments, composition, reply, forward, drafts, and sent-mail history.

Implementation starts with reliable inbound receipt and local ownership of email
because every later client workflow depends on durable, replayable message data.
Manifold does not attempt to become a general-purpose Internet MTA in Release
0.1.

### 4.2 Durable acceptance before acknowledgement

An SMTP `250` response is a durability promise. Manifold must not return `250` until:

1. The raw message and its transport manifest have been synchronously written to the persistent spool.
2. The spool bundle has been atomically moved into its ready state.
3. The PostgreSQL acceptance transaction has committed.
4. The asynchronous archival job has been inserted transactionally.

After those steps, the sender may safely delete its copy.

### 4.3 Raw message as the immutable source of truth

The RFC 5322 message received after SMTP transparency removal is retained unchanged. Parsed headers, bodies, attachments, search documents, thread assignments, and security decisions are derived projections that may be rebuilt.

SMTP envelope data and transport metadata are stored separately. Manifold does not trust sender-supplied `Received` or `Authentication-Results` headers as local transport facts.

### 4.4 Thin protocol edge

The SMTP session process performs only work required to complete the protocol safely:

- Parse and validate commands.
- Resolve recipients.
- Enforce protocol and resource limits.
- Persist the durable spool bundle.
- Commit the acceptance transaction.
- Return the correct SMTP result.

MIME parsing, attachment extraction, HTML sanitization, search indexing, security scanning, routing rules, notifications, and provider calls must not run synchronously in the SMTP session.

### 4.5 Functional core, supervised effects

Address normalization, recipient resolution, state transitions, provider-event normalization, and policy decisions should be implemented as pure transformations wherever practical.

Processes exist for lifecycle, concurrency, scheduling, or resource ownership. A database context or pure calculation must not be wrapped in a GenServer merely to make it “OTP-based.”

### 4.6 Idempotent asynchronous stages

Every asynchronous stage is keyed by the immutable inbound delivery ID. Retried jobs must be safe. Database constraints, explicit state transitions, and idempotency keys are preferred over in-memory locks.

### 4.7 PostgreSQL is the metadata source of truth

Mailbox state, delivery state, routing configuration, provider events, and audit records live in PostgreSQL. ETS may be used only as a disposable cache.

### 4.8 Storage is replaceable

The mail domain does not depend directly on a particular object store library. Raw messages and extracted blobs are accessed through narrow behaviours. The initial development adapter uses the local filesystem; production may use ESS or another S3-compatible service.

### 4.9 Provider-owned Internet delivery

Once a configured provider accepts an outbound message, the provider owns Internet retry, DKIM signing, bounce generation, suppression management, and recipient-MX interaction. Manifold retains the local submission state and reconciles provider webhooks.

### 4.10 One modular monolith before distributed services

Release 0.1 is one OTP release with explicit application boundaries. It must not introduce network services between internal components. The boundaries exist to control dependencies, supervision, and future extraction—not to create premature distributed systems.

---

## 5. System Context

Current main mail receipt uses provider connectors or local pulls from the
separate SMTP edge. The diagram below records the original inbound pipeline;
the SMTP listener and initial spool run at the edge in the current deployment.
Provider imports enter the main durable spool and ingest boundary directly.
Only the local filesystem object-store adapter is implemented; ESS/S3 remains
a target adapter.

```text
                            INBOUND

Remote sender MTA
        |
        | SMTP / TCP 25
        v
+-----------------------+
| manifold_smtp         |
| protocol + limits     |
+-----------+-----------+
            |
            | resolved envelope + raw DATA
            v
+-----------------------+
| persistent spool      |
| raw.eml + manifest    |
+-----------+-----------+
            |
            | acceptance transaction
            v
+-----------------------+       +----------------------+
| PostgreSQL            |------>| Styx                |
| transport metadata    |       | durable jobs        |
+-----------------------+       +----------+-----------+
                                            |
                                            v
                                +----------------------+
                                | archival + pipeline  |
                                +----------+-----------+
                                           |
                         +-----------------+-----------------+
                         |                                   |
                         v                                   v
              +----------------------+           +----------------------+
              | ESS / S3 / filesystem|           | parsed projections   |
              | raw and attachments  |           | PostgreSQL           |
              +----------------------+           +----------------------+
                                                            |
                                                            v
                                                 +----------------------+
                                                 | Phoenix LiveView/API |
                                                 +----------------------+
                                                            ^
                                                            |
                                                   web browser / user


                            OUTBOUND

Phoenix/API -> local outbound queue -> provider adapter -> paid provider
                                                    |
                                                    v
                                      delivery/bounce webhooks
                                                    |
                                                    v
                                             PostgreSQL
```

---

## 6. Umbrella Structure

The current umbrella structure is:

```text
manifold/
├── apps/
│   ├── manifold_core/
│   ├── manifold_data/
│   ├── manifold_accounts/
│   ├── manifold_contacts/
│   ├── manifold_calendars/
│   ├── manifold_account_lifecycle/
│   ├── manifold_storage/
│   ├── manifold_ingest/
│   ├── manifold_smtp/
│   ├── manifold_mail/
│   ├── manifold_security/
│   ├── manifold_outbound/
│   ├── manifold_cloud/
│   ├── manifold_edge/
│   ├── manifold_connectors/
│   ├── manifold_web/
│   └── manifold_api/
├── config/
├── docs/
├── flake.nix
├── devenv.nix
└── devenv.yaml
```

`manifold_smtp` starts only in the separate edge release. The main release
contains Contacts, Calendars, and Account Lifecycle alongside the mail client.

### 6.1 `manifold_core`

Owns stable, infrastructure-independent concepts:

- Shared identifiers and typed value objects.
- Email address and domain normalization.
- Shared error types.
- State-transition helpers.
- Domain event definitions.
- Common Telemetry event naming.
- Clock and ID behaviours for deterministic tests.

It must not own database access, SMTP listeners, HTTP clients, or business workflows.

### 6.2 `manifold_data`

Owns shared persistence infrastructure:

- `Manifold.Repo`.
- Ecto repository configuration.
- Centralized database migrations.
- Styx repository integration and supervision.
- Database health checks.
- Transaction helpers that do not contain domain policy.

Domain schemas may live in their owning applications while migrations remain centralized.

### 6.3 `manifold_accounts`

Owns recipient-address configuration and resolution:

- Domains.
- Mailboxes.
- Mailbox ownership or membership.
- Aliases.
- Alias targets.
- Plus-addressing policy.
- Active, suspended, and disabled states.
- Recipient resolution.

Its public API returns explicit routing decisions. SMTP code must not query schemas directly.

Example conceptual result:

```elixir
{:ok,
 %Manifold.Accounts.Route{
   original_recipient: "...",
   canonical_recipient: "...",
   plus_tag: nil,
   mailbox_ids: [...]
 }}
```

Expected lookup failures return tagged values, not exceptions.

### 6.4 `manifold_storage`

Owns persistent ingress spooling and object/blob storage abstractions:

- Durable spool bundle creation.
- Atomic spool state transitions.
- Spool capacity checks.
- Orphan and cleanup reconciliation.
- Raw-message store behaviour.
- Attachment/blob store behaviour.
- Local filesystem adapter.
- ESS/S3-compatible adapter.

The persistent spool is not a temporary directory. It is part of the acceptance protocol and must use a durable local filesystem.

### 6.5 `manifold_ingest`

Owns the transport-to-mailbox acceptance workflow:

- Acceptance command.
- PostgreSQL acceptance transaction.
- Creation of transport recipients and mailbox entries.
- Transactional Styx job insertion.
- Delivery lifecycle state.
- Archival job.
- Processing-stage orchestration.
- Durable message events.
- Recovery and retry decisions.

This application defines the acceptance boundary used by local
`manifold_smtp`, by `manifold_cloud` edge imports, and by
`manifold_connectors` provider imports. Provider imports use a distinct
transport-neutral API and do not create SMTP recipient facts.

### 6.6 `manifold_smtp`

Owns the inbound SMTP edge:

- Listener lifecycle.
- Session callbacks.
- SMTP command semantics.
- Peer and HELO metadata.
- Recipient validation through a configured resolver boundary.
- Message-size and recipient-count limits.
- STARTTLS configuration.
- SMTP response mapping.
- Session Telemetry.
- Connection and abuse controls.

The initial implementation may use `gen_smtp`, isolated behind a Manifold adapter so the protocol engine can be replaced later if streaming `DATA` is required.
The transport application has no production dependency on Accounts or Ingest.
The current main release excludes it; the edge release configures
`Manifold.Edge.SMTP`. Local resolver/ingest adapters remain available for scoped
integration tests of the original inbound contract.

### 6.7 `manifold_mail`

Owns normalized mail content:

- MIME parsing.
- Header preservation and indexed header projection.
- Text and HTML body selection.
- Attachment extraction and metadata.
- Threading.
- Mailbox presentation projection.
- Search-document generation.
- Reprocessing from raw message data.

No parsed representation may be treated as more authoritative than the raw message and envelope metadata.

### 6.8 `manifold_security`

Owns mail security and policy evaluation:

- SPF result integration.
- DKIM verification.
- DMARC evaluation.
- Malware-scanner adapters.
- Spam-classifier adapters.
- Quarantine decisions.
- Security-result persistence.

Release 0.1 may begin with explicit `not_evaluated` results and adapter contracts. It must not fabricate successful authentication results.
Safe HTML sanitization and resource enforcement remain owned by
`manifold_mail` and `manifold_web`; security supplies policy decisions rather
than presentation code.

### 6.9 `manifold_outbound`

Owns managed-provider submission:

- Outbound message lifecycle.
- Provider behaviour.
- Provider-specific adapters.
- Direct managed-provider HTTPS integration where precise retry semantics are
  required.
- Styx submission jobs.
- Provider idempotency keys.
- Webhook signature verification.
- Delivery, bounce, complaint, and suppression events.
- Retry classification.

It must not contain direct MX lookup or SMTP delivery to recipient servers.

### 6.10 `manifold_web`

Owns the Phoenix webmail application:

- Domain, mailbox, and alias administration.
- Inbox, thread, message, and search views.
- Read, unread, starred, archived, and folder interactions.
- Safe body rendering.
- Attachment download.
- Compose, draft, reply, reply-all, and forward workflows.
- Sent-mail and outbound-delivery status.
- Operational status.
- External account OAuth, status, sync-now, and disconnect controls.
- Provider webhook endpoints.
- LiveView updates through PubSub.

### 6.11 `manifold_cloud`

Owns the local side of optional cloud ingress:

- Complete recipient snapshot publication.
- Signed HTTPS client operations.
- Bounded pending-delivery pulls.
- Streamed raw transfer into the local spool.
- Idempotent edge provenance acceptance.
- Permanent poison-delivery isolation without blocking later deliveries.
- Durable Styx publication and pull jobs.
- Acknowledgement only after local acceptance commits.

It initiates every synchronization connection. The edge never calls into the
local installation.

### 6.12 `manifold_edge`

Owns the standalone cloud ingress release:

- Edge-only PostgreSQL Repo and migrations.
- Installed recipient snapshots and replay nonces.
- Edge SMTP resolver and durable acceptance rows.
- Signed machine API for list, raw read, status, acknowledgement, and permanent
  import-failure isolation.
- Acknowledgement tombstones and spool reconciliation.

It does not depend on local Accounts, Ingest, Mail, Security, Outbound, or Web
applications and stores no long-term mailbox state.

### 6.13 `manifold_connectors`

Owns external mailbox synchronization and shared Gmail/Microsoft authorization
lifecycle:

- OAuth authorization transactions, PKCE, and Microsoft device-code login.
- Encrypted access and refresh credentials, including incremental Gmail and
  Microsoft receive/send grants.
- Gmail and Microsoft Graph provider adapters.
- Provider account, message identity, cursor, and operational event schemas.
- Bounded Styx synchronization and remote-state jobs.
- Mapping provider identities to durable local inbound deliveries.
- IMAP and EAS receive methods, read-state writeback, and SMTP credential checkout.
- Account-owned iCloud Contacts credentials and DAV synchronization, plus independent
  Calendar credentials, Google/iCloud adapters and generation/lease-fenced jobs.

The application depends only on public APIs from Core, Data, Accounts, Ingest,
and Mail. Provider adapters never write another application's schemas directly.
They fetch provider-supplied raw RFC message bytes and pass them through
`Manifold.Ingest.import_external/3`.

The synchronization side of this boundary is read-only with respect to Gmail and
Microsoft 365. It does not mutate remote messages, register push subscriptions,
or implement direct outbound MX delivery. It exposes checked-out Gmail and
Microsoft send credentials to `manifold_outbound`, which owns rendering and
submission.

Contact, calendar, and DAV resource schemas are shared contracts in
`manifold_data`. The local Contacts/Calendars contexts and the connector sync
pipeline use these contracts without depending on each other's private schemas.

### 6.14 `manifold_api`

Owns the HTTP machine interface for local mail read and search:

- Versioned REST under `/api/v1`.
- GraphQL under `/api/graphql` (GraphiQL only in non-production).
- Product discovery at `GET /.well-known/manifold` (absolute REST/GraphQL URLs,
  version, and `auth: deployment_boundary`).
- Shared JSON serialization for mailbox, folder, conversation, body, and
  attachment metadata.
- Attachment binary download over REST only; GraphQL exposes REST attachment
  URLs rather than binary payloads.
- Structured `Manifold.Core.Error` mapping to HTTP status and JSON error bodies.

It runs as a separate Phoenix Endpoint on `API_PORT` (default `4292`) and depends
only on public Accounts and Mail context APIs. It does not own compose/send,
domain/alias administration, provider webhooks, or application-level auth.
Clients should target the API host; if a reverse proxy merges hosts, forward
`/.well-known/manifold` to this endpoint.

Phoenix LiveView using Phoenix Duskmoon components is the product frontend.
Duskmoon Bundler owns JavaScript, CSS, and Tailwind asset builds. A separate SPA
or native desktop client is not required.

### 6.15 `manifold_contacts` and `manifold_calendars`

Both applications depend on `manifold_data`. Contacts owns local contact CRUD,
search, Account assignment, and opt-in sync intentions. Calendars owns independent
local calendar/event CRUD, bounded occurrence expansion, timezone semantics and
transactional intents for multiple targets. Neither context performs network I/O;
`manifold_connectors` executes provider work from shared durable resource state.
Calendar connection/binding/resource/component/immutable-attempt schemas belong
to Data. Each target keeps independent desired/acknowledged revisions and a common
semantic baseline; only accepted canonical changes propagate to other targets.
See [CALENDARS.md](CALENDARS.md) and [ICLOUD.md](ICLOUD.md).

### 6.16 `manifold_account_lifecycle`

Owns durable Account disable/purge orchestration through public application APIs,
including local mail and iCloud data cleanup. Account purge does not issue cloud
contact or event deletes.

---

## 7. Dependency Direction

The intended dependency tiers are:

```text
Tier 0:
  manifold_core

Tier 1:
  manifold_data
  manifold_storage
  manifold_smtp

Tier 2:
  manifold_accounts
  manifold_mail
  manifold_contacts
  manifold_calendars

Tier 3:
  manifold_security

Tier 4:
  manifold_ingest

Tier 5:
  manifold_cloud
  manifold_connectors

Tier 6:
  manifold_outbound

Tier 7:
  manifold_account_lifecycle

Tier 8:
  manifold_web
  manifold_api

Separate release boundary:
  manifold_edge -> manifold_core + manifold_storage + manifold_smtp
```

Concrete dependencies may be narrower than the tier diagram, but cycles are prohibited.

Important rules:

- `manifold_smtp` calls configured resolver and acceptor behaviours; it has no
  production dependency on Accounts, Ingest, or Edge.
- `manifold_cloud` calls public APIs from Accounts and Ingest.
- `manifold_connectors` calls public APIs from Accounts, Ingest, and Mail.
- `manifold_outbound` checks out send credentials through Connectors.
- Contacts, Calendars, and iCloud sync share Data-owned schemas; local context
  changes persist sync intentions while connector jobs own network effects.
- `manifold_web` and `manifold_api` call public context APIs; they do not
  implement mail policy.
- `manifold_accounts` does not depend on SMTP or Phoenix.
- `manifold_mail` does not depend on the web presentation layer.
- Durable jobs are authoritative; PubSub is only a notification mechanism.
- No application may use another application's private schema modules as an informal API.

---

## 8. Core Domain Model

### 8.1 Transport-level entities

#### `InboundDelivery`

Represents one accepted SMTP transaction and one raw message body.

Important fields:

- `id`
- `ingest_id`
- `peer_ip`
- `helo`
- `envelope_from`
- `received_at`
- `raw_size`
- `raw_sha256`
- `spool_bundle_path`
- `raw_object_key`
- `raw_storage_state`
- `processing_state`
- `last_error`

`ingest_id` is unique and is generated by Manifold. It is the idempotency key for all internal processing stages.

#### `DeliveryRecipient`

Represents one `RCPT TO` address and its resolved mailbox route.

Important fields:

- `inbound_delivery_id`
- `original_address`
- `canonical_address`
- `plus_tag`
- `mailbox_id`

A single original recipient may resolve to multiple mailboxes through an alias. Multiple recipient addresses may also resolve to the same mailbox. The transport record must preserve the original recipient while mailbox projection logic avoids unintended duplicate mailbox entries.

### 8.2 Content-level entities

#### `Message`

Represents the parsed projection of an inbound delivery.

Important fields:

- `inbound_delivery_id`
- `rfc_message_id`
- `subject`
- `from`
- `reply_to`
- `sent_at`
- `parsed_headers`
- `text_body`
- `html_body`
- `parse_version`
- `parse_state`

Repeated headers must not be collapsed into an ordinary map. Preserve ordered header pairs or another representation that retains duplicates.

#### `Attachment`

Represents an extracted MIME part:

- `message_id`
- `content_id`
- `filename`
- `media_type`
- `disposition`
- `size`
- `sha256`
- `object_key`

Untrusted filenames are presentation metadata and must never become storage paths.

### 8.3 Mailbox-level entities

#### `MailboxEntry`

Represents one message as seen in one mailbox:

- `mailbox_id`
- `inbound_delivery_id`
- `message_id`
- `original_recipient`
- `folder` or system label
- `read`
- `starred`
- `quarantined`
- `inserted_at`

Per-mailbox state must not be stored on the shared transport record.

### 8.4 Account entities

- `Domain`
- `Mailbox`
- `Alias`
- `AliasTarget`

Release 0.1 treats access to the local web endpoint as full-instance access.

### 8.5 Outbound entities

- `OutboundMessage`
- `OutboundRecipient`
- `ProviderSubmission`
- `ProviderEvent`

Provider event IDs must be unique per provider so repeated webhook deliveries are idempotent.

### 8.6 Audit and lifecycle entities

`MessageEvent` is an append-only operational and audit record. It is not an event-sourcing system.

Examples:

- `accepted`
- `archive_started`
- `archived`
- `parse_started`
- `parsed`
- `quarantined`
- `outbound_submitted`
- `provider_delivered`
- `provider_bounced`

---

## 9. Recipient Resolution

Release 0.1 uses a deliberate Manifold address policy:

- Domains are ASCII and normalized to lowercase.
- Local parts are preserved in their original form for audit.
- Lookup keys are case-insensitive under Manifold's mailbox policy.
- `SMTPUTF8` is not advertised.
- Exact mailbox resolution is attempted first.
- Exact alias resolution is attempted second.
- Plus addressing is attempted only when enabled for the domain or mailbox.
- Catch-all routing is deferred.

The resolver produces either a complete immutable route or a classified failure:

```text
active mailbox or alias route -> accept recipient
unknown recipient             -> 550 5.1.1
disabled recipient            -> 550 5.1.1 or configured policy
temporary database failure    -> 451 4.3.0
invalid syntax                -> 501 5.1.3
```

The resolved route is frozen for the SMTP transaction. Configuration changes after `RCPT TO` do not retroactively alter the accepted delivery.

---

## 10. SMTP Session Contract

### 10.1 Required command behavior

The first production listener supports:

- `EHLO`
- `HELO`
- `MAIL FROM`
- `RCPT TO`
- `DATA`
- `RSET`
- `NOOP`
- `QUIT`
- `STARTTLS`

Recommended advertised extensions:

- `SIZE`
- `8BITMIME`
- `PIPELINING`
- `STARTTLS`

`AUTH` is not offered on the inbound port.

### 10.2 Configurable limits

At minimum:

- Maximum message size.
- Maximum recipients per transaction.
- Maximum concurrent sessions.
- Per-IP connection rate.
- Per-IP concurrent sessions.
- Command timeout.
- DATA timeout.
- Spool low-space threshold.

A conservative default maximum message size is 25 MiB. Because the initial `gen_smtp` path may buffer `DATA`, concurrency limits must account for worst-case memory usage.

### 10.3 SMTP result mapping

Examples:

```text
250 2.0.0 accepted as <ingest-id>
451 4.3.0 temporary local failure
452 4.3.1 insufficient system storage
550 5.1.1 recipient unknown
552 5.3.4 message size exceeds fixed limit
554 5.7.1 transaction rejected by policy
```

Unknown recipients must be rejected during `RCPT TO`, not accepted and bounced later.

### 10.4 Failure behavior

- Database unavailable during recipient lookup: return a transient `451`.
- Spool capacity below threshold: reject transiently.
- Spool write or sync failure: return a transient failure after `DATA`.
- Acceptance transaction failure: do not return `250`.
- Parsing or object-store failure after acceptance: retry asynchronously; the sender has already fulfilled its responsibility.

---

## 11. Durable Spool Protocol

The persistent spool is the first durability layer.

### 11.1 Bundle layout

```text
<spool-root>/
├── tmp/
│   └── <ingest-id>.partial/
├── ready/
│   └── <ingest-id>/
│       ├── manifest.json
│       └── raw.eml
├── failed/
└── quarantine/
```

The manifest is versioned and contains:

- `version`
- `ingest_id`
- `received_at`
- `peer_ip`
- `helo`
- `envelope_from`
- Original recipients
- Frozen mailbox routes
- Raw byte count
- SHA-256 digest
- SMTP extension metadata required for later processing

### 11.2 Write sequence

1. Generate `ingest_id`.
2. Create a private partial directory.
3. Write `raw.eml`.
4. Write `manifest.json`.
5. Synchronize both files.
6. Synchronize the partial directory where supported.
7. Atomically rename the bundle into `ready/`.
8. Synchronize the parent directory where supported.
9. Execute the PostgreSQL acceptance transaction.
10. Return `250` only after the transaction commits.

User-controlled values never participate in filesystem paths.

### 11.3 PostgreSQL acceptance transaction

One `Ecto.Multi` must:

1. Insert `InboundDelivery` with unique `ingest_id`.
2. Insert all `DeliveryRecipient` rows.
3. Create deduplicated `MailboxEntry` rows.
4. Insert an `accepted` event.
5. Insert the first Styx archival job.

The Styx job and delivery records commit together.

### 11.4 Crash and orphan semantics

The PostgreSQL row is the logical acceptance commit point; the ready spool bundle is the raw durability prerequisite.

Recovery rules:

- Ready bundle plus database row: accepted; ensure the archival job exists.
- Archived database row plus remaining bundle: verify and clean up the bundle.
- Database row plus missing unarchived bundle: mark an operational failure and alert.
- Ready bundle without database row: it was not known to have crossed the acceptance commit point. Move it to an orphan/failed area after a retention period; do not silently expose it as accepted mail.

A sender may retry if the connection fails after database commit but before it receives `250`. This can produce legitimate duplicate deliveries. Manifold may mark probable duplicates, but it must not delete them solely by `Message-ID` or content hash.

---

## 12. Asynchronous Inbound Pipeline

The implemented inbound pipeline is:

```text
accepted
  -> archive raw object
     |-> security evaluation -> allow or retain quarantine
     |-> parse MIME
          -> extract/store attachments
          -> create normalized message
          -> assign thread
          -> finalize mailbox entries
          -> index for search
```

Acceptance creates mailbox entries with quarantine visibility enforced.
Security and MIME projection begin after archival and run independently from
the same verified raw source. The archive transaction inserts both Styx jobs.
Only a committed allow or manual-release policy clears quarantine.

Each stage:

- Receives the inbound delivery ID.
- Reloads authoritative state from PostgreSQL.
- Checks whether its result already exists.
- Performs the side effect.
- Commits the next state and event.
- Retries only classified transient failures.
- Stores terminal errors without losing the raw message.

Styx queues should separate latency-sensitive and resource-intensive work, for example:

- `ingest`
- `archive`
- `mail_parse`
- `security`
- `outbound`
- `maintenance`

PubSub may notify LiveView after a committed change, but PubSub must never be the only trigger for durable work.

---

## 13. Raw and Attachment Storage

### 13.1 Raw store behaviour

The interface should remain narrow:

```text
put_from_path(object_key, local_path, metadata)
open_or_stream(object_key)
stat(object_key)
delete(object_key)
```

The exact Elixir callback signatures may vary, but the behaviour must support streaming and avoid requiring the entire object in memory.

### 13.2 Object keys

Object keys are generated from trusted IDs:

```text
raw/<domain-id>/<yyyy>/<mm>/<inbound-delivery-id>.eml
blobs/sha256/<first-two-hex>/<sha256>
```

Do not use sender filenames, subjects, or `Message-ID` values in keys.

### 13.3 Storage adapters

The current local implementation includes:

1. Local filesystem raw-message adapter.
2. Local filesystem content-addressed attachment adapter.

An ESS/S3-compatible adapter remains planned. Adding it must not change mail or
ingest context APIs.

The application must remain available for SMTP receipt during a temporary object-store outage as long as the persistent spool has capacity.

### 13.4 Attachment blobs

Attachments may be content-addressed by SHA-256. Database rows retain presentation metadata and object references. Garbage collection must be explicit and reference-aware; Release 0.1 may defer automated blob deletion.

---

## 14. Mail Parsing and Presentation

### 14.1 Parsing rules

- Parse asynchronously.
- Preserve repeated and ordered headers.
- Store selected headers in indexed columns.
- Treat malformed MIME as data, not as a reason to lose the delivery.
- Record parser version so projections can be rebuilt.
- Limit recursive multipart depth.
- Limit total extracted parts.
- Never automatically unpack archives.

### 14.2 Bodies

Manifold should identify:

- Preferred text body.
- Preferred HTML body.
- Alternative bodies.
- Inline MIME parts.
- Attachments.

The original HTML is untrusted.

The normalized text body is stored in full within the configured message-size
limit. Basic PostgreSQL search indexes the subject, sender address, and first
32,768 characters of normalized text body. This deliberate projection bound prevents a
sender-controlled message from exceeding PostgreSQL's `tsvector` size limit;
the immutable raw message and complete normalized body remain available.

### 14.3 Safe rendering

The web layer must:

- Sanitize HTML.
- Block scripts, forms, active embeds, and unsafe URLs.
- Block remote images by default.
- Render mail content in an isolated container.
- Avoid applying application CSS to untrusted message HTML.
- Serve risky attachments as downloads.
- Set defensive content types and content-disposition headers.

### 14.4 Threading

Primary threading inputs:

- `Message-ID`
- `In-Reply-To`
- `References`

Subject-based fallback may be added conservatively but must not merge unrelated conversations aggressively.

### 14.5 Webmail interaction model

The web interface presents mailbox projections rather than raw transport rows.
Expected email-client workflows include:

- Browse inbox, sent, drafts, archive, trash, and configured folders.
- Open individual messages and conversation threads.
- Mark messages read or unread.
- Star, archive, restore, move, and delete mailbox entries.
- Search message metadata and indexed body content.
- Compose, save drafts, reply, reply-all, and forward.
- Download attachments and control remote-image loading.
- Inspect delivery or security details without exposing storage paths.

These workflows are delivered incrementally. Milestone 1 exposes accepted
deliveries for operational verification. Milestone 2 adds inbox, folder,
conversation, search, attachment, and mailbox-state workflows. Compose, reply,
sent mail, and provider state arrive with managed outbound delivery.

---

## 15. Security Architecture

### 15.1 Transport security

- Opportunistic STARTTLS on port 25.
- Certificates configured at runtime.
- No inbound SMTP authentication.
- Explicit connection, command, recipient, and message limits.
- Peer IP and HELO retained for policy evaluation.
- TLS failure must not corrupt an SMTP session state machine.

### 15.2 Message authentication

`manifold_security` stores explicit results:

- `pass`
- `fail`
- `softfail`
- `neutral`
- `none`
- `temperror`
- `permerror`
- `not_evaluated`

SPF evaluation uses the peer IP, HELO identity, and envelope sender. DKIM uses the preserved raw message. DMARC combines aligned SPF/DKIM results and domain policy.

A Release 0.1 implementation may integrate an external verifier or initially mark checks as `not_evaluated`, but it must never infer `pass` from untrusted headers.

### 15.3 Abuse and content controls

- Per-IP rate limiting.
- Per-IP and global connection concurrency limits.
- Per-IP connection and SMTP transaction fixed-window limits.
- Recipient-count limits.
- Message-size limits.
- Spool capacity backpressure.
- Attachment-size and part-count limits.
- Optional malware scanner adapter.
- Optional spam-classifier adapter.
- Quarantine rather than backscatter after acceptance.

### 15.4 Secrets

Provider credentials, database credentials, storage credentials, and TLS private keys are runtime secrets. They must not be committed. The deployment is expected to work cleanly with Nix and secret-management systems such as sops-nix.

---

## 16. Outbound Delivery

### 16.1 Submission flow

```text
compose/API request
  -> validate sender identity
  -> persist outbound message
  -> insert Styx submission job
  -> render provider request
  -> call provider API
  -> store provider message ID
  -> process provider webhooks
```

### 16.2 Provider behaviour

A provider adapter should expose operations equivalent to:

- Submit a message.
- Normalize synchronous provider errors.
- Verify a webhook.
- Normalize provider events.
- Classify retryable and terminal failures.

Provider-specific data should be retained in a namespaced JSON field but must not leak throughout the domain model.

### 16.3 Delivery state

Outbound-message submission states:

- `draft`
- `queued`
- `submitting`
- `accepted_by_provider`
- `failed`
- `submission_uncertain`

Each recipient independently tracks:

- `pending`
- `sent`
- `delayed`
- `delivered`
- `bounced`
- `complained`
- `suppressed`
- `failed`

“Accepted by provider” is not the same as “delivered.”

### 16.4 Idempotency

- Each outbound message has a Manifold idempotency key.
- Retries reuse the same provider idempotency key when supported.
- Provider webhook events have provider-scoped unique IDs.
- Repeated webhooks must not duplicate state transitions.

### 16.5 No direct Internet MTA

No Release 0.1 code should:

- Resolve recipient MX records for delivery.
- Open SMTP sessions to arbitrary recipient servers.
- Maintain an outbound MTA retry queue.
- Generate Internet-facing DSNs independently of the provider.

---

## 17. Phoenix Webmail and API

### 17.1 Primary client interface

Phoenix LiveView is the primary way users read and manage mail. The target
interface includes:

- Mailbox inbox.
- Folder and mailbox navigation.
- Conversation and message lists.
- Message detail.
- Search.
- Read, unread, starred, archive, move, and trash actions.
- Compose, draft, reply, reply-all, and forward.
- Sent-mail and provider-delivery status.
- Attachment download.
- Safe text and HTML body rendering.
- Responsive layouts suitable for desktop and mobile browsers.

The UI should behave like an email client, not an infrastructure dashboard.
Operational details remain available but are secondary to reading and managing
mail.

### 17.2 Incremental interface

The inbound-first milestone includes:

- Domain list and domain status.
- Mailbox list.
- Alias management.
- Inbound delivery list.
- Raw-header and transport metadata view.
- Processing and failure status.
- Operational spool and queue health.

Milestone 2 adds the primary `/` inbox, mailbox/folder navigation, conversation
reading, search, safe HTML bodies, attachment downloads, and read/star/archive/
move/trash state. Compose, reply, sent-mail, and provider-event views are added
with the managed outbound milestone.

### 17.3 API principles

- Versioned JSON API under `/api/v1`.
- GraphQL under `/api/graphql`.
- Discovery document at `GET /.well-known/manifold` on the API endpoint.
- Stable resource IDs.
- Cursor pagination for message lists.
- Explicit deployment-boundary access policy.
- No direct exposure of object-store keys.
- Signed or controller-mediated attachment downloads.
- Idempotency key support for message creation.
- Structured error responses.

Candidate resources:

```text
/.well-known/manifold
/api/v1/domains
/api/v1/mailboxes
/api/v1/mailboxes/:id/messages
/api/v1/messages/:id
/api/v1/outbound-messages
/api/v1/provider-webhooks/:provider
```

### 17.4 Access model

Release 0.1 has no application-level web authentication or mailbox authorization.
Anyone who can reach the local web endpoint has full-instance access. Deployments
must enforce their desired trust boundary through host networking or a trusted
reverse proxy.

This is a deliberate single-installation client model: opening the web
application is equivalent to opening a locally trusted desktop email client.

### 17.5 Real-time updates

LiveView updates use Phoenix PubSub after database commits. The UI must reload authoritative data rather than treating PubSub payloads as the source of truth.

---

## 18. OTP and Supervision Model

A conceptual supervision structure for the original local inbound release was:

```text
Manifold.Supervisor
├── Manifold.Repo
├── Styx
├── Phoenix.PubSub
├── Manifold.Storage.Supervisor
│   ├── SpoolCapacityMonitor
│   └── SpoolReconciler
├── Manifold.SMTP.Supervisor
│   └── SMTP listener / acceptor pool
└── ManifoldWeb.Endpoint
```

Current supervision is spread across the umbrella application supervisors.
The main release does not start SMTP; the separate edge release owns its SMTP
listener and Repo, and does not start local webmail, contacts, or calendars.

Additional rules:

- SMTP sessions are isolated processes owned by the SMTP library or listener.
- No single GenServer serializes all incoming messages.
- Spool writes use per-delivery files and atomic filesystem operations.
- Jobs provide durable concurrency and retry.
- Caches are rebuildable.
- A process crash must not invalidate already committed acceptance state.
- Supervisors restart infrastructure; they do not conceal corrupt persistent state.

---

## 19. Observability

### 19.1 Telemetry

Recommended event families:

```text
[:manifold, :smtp, :connection, :start | :stop | :exception]
[:manifold, :smtp, :transaction, :stop]
[:manifold, :smtp, :recipient, :accepted | :rejected]
[:manifold, :ingest, :accept, :start | :stop | :exception]
[:manifold, :spool, :write, :stop]
[:manifold, :archive, :stop]
[:manifold, :mail, :parse, :stop]
[:manifold, :ingest, :security, :stop]
[:manifold, :security, :policy, :committed]
[:manifold, :security, :evaluation, :failed]
[:manifold, :smtp, :admission, :connection | :transaction]
[:manifold, :connectors, :oauth, :start | :complete | :refresh, :stop]
[:manifold, :connectors, :microsoft, :folder_mapping, :stop]
[:manifold, :connectors, :sync, :stop]
[:manifold, :outbound, :send_method, :select, :stop]
[:manifold, :outbound, :submit, :stop]
[:manifold, :provider, :webhook, :processed]
```

Measurements should include duration, attempts, changed-row counts, and byte
counts where appropriate. The connector OAuth/folder/sync and outbound
selection/submission families use only internal IDs, provider/method kind,
outcome, and fixed normalized error codes. Their telemetry never includes
provider message IDs, free-form provider errors, addresses, recipients,
subjects, bodies, Bcc, MIME, authorization codes, or credentials.

### 19.2 Logs

Structured logs should include, where applicable:

- `ingest_id`
- `inbound_delivery_id`
- `mailbox_id`
- `peer_ip`
- pipeline stage
- retry classification
- provider
- provider event ID

Do not log full message bodies, authentication headers, provider secrets, or attachment content.

### 19.3 Operational health

Expose health for:

- PostgreSQL.
- Styx queue latency.
- Spool capacity and oldest bundle age.
- Object-store reachability.
- SMTP listener state.
- TLS certificate expiry.
- Failed/quarantined delivery counts.
- Provider webhook lag.

---

## 20. Deployment Model

### 20.1 Historical direct local ingress

This was the original deployment target. Current SMTP ingress uses the separate
`manifold_edge` release in section 21; the main release is a provider mail client
and does not start an inbound SMTP listener. ESS/S3 below remains a target store,
not an implemented adapter.

```text
Internet
   |
   | TCP 25
   v
Manifold host
   ├── OTP release
   ├── persistent spool volume
   ├── PostgreSQL
   └── ESS/S3-compatible raw store
```

Required DNS and network configuration:

- MX record for each hosted domain.
- A or AAAA record for the MX hostname.
- Public TCP port 25 reachability.
- Stable SMTP hostname.
- STARTTLS certificate.
- Provider-specific SPF, DKIM, and return-path records for outbound mail.

### 20.2 Runtime configuration

The following list combines original local-ingress configuration and connector
configuration. `MANIFOLD_SMTP_*` configures the separate edge listener in current
deployments; it does not enable a listener in the main release. Some storage and
provider entries describe target or legacy adapters rather than current choices.

```text
DATABASE_URL
MANIFOLD_SMTP_HOSTNAME
MANIFOLD_SMTP_BIND
MANIFOLD_SMTP_PORT
MANIFOLD_SMTP_MAX_MESSAGE_BYTES
MANIFOLD_SMTP_MAX_RECIPIENTS
MANIFOLD_SMTP_MAX_CONNECTIONS
MANIFOLD_SMTP_MAX_CONNECTIONS_PER_PEER
MANIFOLD_SMTP_CONNECTION_RATE_LIMIT
MANIFOLD_SMTP_CONNECTION_RATE_WINDOW_MS
MANIFOLD_SMTP_TRANSACTION_RATE_LIMIT
MANIFOLD_SMTP_TRANSACTION_RATE_WINDOW_MS
MANIFOLD_SMTP_ACCEPTORS
MANIFOLD_SMTP_TLS_CERTFILE
MANIFOLD_SMTP_TLS_KEYFILE
MANIFOLD_SPOOL_DIR
MANIFOLD_SPOOL_MIN_FREE_BYTES
MANIFOLD_RAW_STORE_BACKEND
MANIFOLD_RAW_STORE_DIR
MANIFOLD_RAW_STORE_BUCKET
MANIFOLD_OUTBOUND_PROVIDER
MANIFOLD_CONNECTOR_ENCRYPTION_KEY
MANIFOLD_GMAIL_AUTHORIZATION_URL
MANIFOLD_GMAIL_TOKEN_URL
MANIFOLD_GMAIL_USERINFO_URL
MANIFOLD_GMAIL_API_BASE_URL
MANIFOLD_MICROSOFT_AUTHORIZATION_URL
MANIFOLD_MICROSOFT_TOKEN_URL
MANIFOLD_MICROSOFT_API_BASE_URL
SECRET_KEY_BASE
PHX_HOST
```

Scoped local SMTP integration tests use a non-privileged port such as 2525.
The production local release requires
`MANIFOLD_CONNECTOR_ENCRYPTION_KEY` to decode to exactly 32 bytes. It remains the
out-of-database master key for connector ciphertext. Google and Microsoft client
credentials are stored through Settings → OAuth; legacy client-credential
environment values are ignored and never imported or used as fallback. Provider
endpoint overrides remain static operator configuration and must be absolute
HTTPS URLs without credentials or fragments. For Microsoft, only authorization,
token, and Graph base URL overrides remain; the default authority is `common`
for work/school and personal Microsoft accounts.

### 20.3 Nix development environment

The repository should provide:

- `flake.nix`
- `devenv.nix`
- `devenv.yaml`
- A PostgreSQL development service.
- Reproducible Erlang, Elixir, Node/frontend tooling, and required native packages.
- Commands for setup, migration, tests, and local server startup.

### 20.4 Backup and recovery

Back up:

- PostgreSQL.
- Raw object storage.
- Attachment blobs.
- Runtime configuration and secret references.
- Persistent spool while it contains unarchived accepted messages.

The system should resume Styx jobs and spool reconciliation after restart.

---

## 21. Optional Cloud Ingress Edge

The separate `manifold_edge` Release 0.2 deployment can receive SMTP in a cloud
environment and synchronize accepted mail to a local Manifold instance.

Recommended design:

```text
Internet SMTP
      |
      v
Cloud Manifold Edge
  ├── recipient route snapshot
  ├── durable spool
  └── authenticated queue API
      ^
      | local-initiated pull over HTTPS/mTLS
      |
Local Manifold
```

Properties:

- The edge rejects unknown recipients during `RCPT TO`.
- The local server publishes a signed/versioned recipient-routing snapshot.
- The edge durably accepts and assigns an immutable edge delivery ID.
- The local server pulls messages, commits them through the same ingest boundary, and acknowledges by ID.
- The edge deletes only after durable local acknowledgement.
- Synchronization is idempotent.
- Local-initiated pull avoids requiring inbound access to the home network.
- The edge stores no long-term mailbox state.

This must reuse the same `manifold_ingest` acceptance contract instead of creating a second mail model.

---

## 22. External Mailbox Connectors

Milestone 6 adds read-only Gmail and Microsoft 365 synchronization. The
provider is an external source, while PostgreSQL, the raw store, and Manifold's
mailbox projection remain the local source of truth.

```text
Gmail API or Microsoft Graph
          |
          | pull raw RFC message bytes
          v
manifold_connectors
          |
          | trusted provider identity and target mailbox
          v
durable spool -> manifold_ingest -> raw store -> mailbox projection
```

### 22.1 OAuth and credential boundary

- Connector OAuth remains limited to trusted, code-defined providers. Gmail and
  Microsoft both resolve their client credentials from database-backed Settings.
- Authorization-code login uses PKCE `S256`; Microsoft also supports device-code
  login with a public client ID and no callback or client secret.
- The random state value is persisted only as a SHA-256 digest, expires after a
  bounded interval, and is consumed once under a database lock.
- PKCE verifiers and provider tokens use versioned AES-256-GCM envelopes.
- Encryption associated data binds credentials to their account and purpose.
- `connector_oauth_provider_settings` stores one generic row per catalog provider.
  The client ID is plaintext; the client secret is encrypted with associated data
  `oauth_provider_setting:<setting-id>:client_secret`. Decrypted credentials are
  available only inside the connector resolver and never in safe views.
- Gmail receive requests `openid`, `email`, and
  `https://www.googleapis.com/auth/gmail.readonly`; Gmail send incrementally adds
  `https://www.googleapis.com/auth/gmail.send` to the same authorization.
- Gmail uses the OpenID UserInfo `sub` as the durable account identity; its
  email address remains mutable display metadata.
- Microsoft uses `openid`, `profile`, `offline_access`, `User.Read`, and
  purpose-scoped delegated mail permissions. Receive uses `Mail.Read`; adding a
  send method incrementally adds `Mail.Send` to the same authorization.
- Returned read scopes are validated before account activation.
- Refresh-token rotation never erases an existing refresh token when the
  provider omits a replacement.
- A provider account identity is permanently bound to its first active local
  mailbox and reauthorization cannot silently move that account.
- Gmail and Microsoft OAuth start, code exchange, refresh, receive sync,
  configured-provider discovery, and send checkout all resolve the current
  database setting through `Manifold.Connectors.ProviderConfig`; there is no
  credential cache, so saves and removals take effect without restart.
- OAuth start snapshots the provider-setting UUID and `lock_version`. Callback
  completion revalidates that generation before exchange and again after external
  provider I/O inside the final persistence transaction. The provider advisory
  lock is transaction-scoped and is never held during network I/O.
- Missing Google or Microsoft settings fail closed as `provider_not_configured`;
  undecryptable settings use `provider_configuration_error` in sanitized
  telemetry. Browser HTML, LiveView assigns, logs, telemetry, activity events,
  and errors must contain neither plaintext secrets nor ciphertext.

The standard callback paths for browser redirect login are:

```text
https://<PHX_HOST>/connectors/gmail/callback
https://<PHX_HOST>/connectors/microsoft/callback
```

Local development uses the same paths at `http://localhost:4290`. Gmail settings
can store an exact registered callback URL; legacy settings without one retain
the configured Endpoint-derived URL. The exact redirect URI is stored with the
OAuth transaction and must match at completion. Gmail also supports pasting the
final redirected browser URL to complete login when localhost is unreachable;
the server parses that URL without fetching it. Microsoft device-code login
needs no callback, and new Microsoft settings default to that flow. See
[OAUTH_SETUP.md](OAUTH_SETUP.md) for current provider-specific setup.

Operators configure Google and Microsoft at `/settings/oauth`; provider-specific
setup help is at `/settings/oauth/gmail/help` and
`/settings/oauth/microsoft/help`. The help routes and settings cards are resolved
only from `Manifold.Connectors.OAuthProviderCatalog`, so users cannot supply
arbitrary OAuth endpoints or scopes. The current Settings surface is a
trusted-local boundary, not an authenticated administrator interface.

For authorization-code login, changing either provider's client ID requires a
new secret. With an unchanged client ID, a blank secret safely preserves the
current ciphertext and a nonblank secret rotates it. Microsoft's device-code
setting does not require a secret. Save, rotation, client-ID/flow/callback change,
and removal serialize through a provider advisory lock. Every actual credential
or login-configuration change or removal marks the
affected provider's grants and receive/send methods `reconnect_required` and
disables the methods; no method resumes automatically. Removal does not revoke
the remote Google or Microsoft grant.

Provider definitions live in
`Manifold.Connectors.OAuthProviderCatalog` and
`Manifold.Connectors.OAuthProvider.<Provider>`. A definition supplies a stable
key, name, icon, callback path, capabilities, scopes, non-secret runtime endpoints,
and provider help content/links. Adding a provider requires code and tests, plus
its lifecycle integration with OAuth completion, refresh, receive, send, and
dependency transitions. The generic settings table requires no provider-specific
schema migration, but existing OAuth authorization, method-kind, and outbound
provider constraints still require a new migration before that provider can be a
usable connector.

Operators must enable the Gmail API, configure both `gmail.readonly` and
`gmail.send` on the Google OAuth consent screen, and register the exact production
HTTPS callback. While the consent application is in testing mode, every Gmail
identity must be listed as a test user. Public use requires completing Google's
consent publication and scope-verification process. The connector encryption key
must remain stable across releases; real client credentials and deployment
endpoints are never stored in this design document or the repository.

Migration `20260818000100_add_oauth_provider_settings.exs` was the original
non-rolling Gmail cutover. Drain old Phoenix, connector, and Oban processes before
applying it. There is no environment import or fallback: Gmail remains unavailable
until Google credentials are saved in Settings → OAuth, and existing Gmail grants
require reconnect. Rollback refuses while provider-setting rows or fenced OAuth
transactions exist.

The 2026-08-27 Microsoft catalog adoption is a separate code-only, non-rolling
cutover with no migration. Stop new Microsoft submissions, drain queued and
executing Microsoft send work, then drain all old Phoenix, connector, and Oban
processes before deploying the new binary. Only Microsoft remains unavailable
until its Settings credentials are saved, and existing Microsoft grants and
methods require reconnect. The existing Google setting, grants, and methods remain
valid; operators must not rotate or remove Google credentials for this Microsoft
cutover. Staging must verify immediate Microsoft picker enablement after save, the
exact Microsoft help callback, receive and send, rotation/removal reconnect
behavior, and absence of automatic method resumption.

Microsoft uses the `common` authority for work/school and Outlook.com personal
accounts. The application registration must allow both organizational and
personal Microsoft accounts.
Operators must register the exact production HTTPS callback, configure delegated
`User.Read`, `Mail.Read`, and `Mail.Send`, save the client ID and secret at
`/settings/oauth`, restrict staging to a non-production app registration and
approved test users, and obtain tenant admin consent where the tenant disables
user consent. Only Microsoft authorization, token, and Graph base URL environment
overrides remain. The connector encryption key must be backed up and rotated only
through a coordinated credential migration.

### 22.2 Provider synchronization

Gmail freezes the profile `historyId`, scans all message IDs including spam and
trash, fetches each message with `format=RAW`, and then advances through Gmail
history. An expired history cursor starts a non-destructive full scan.

Microsoft Graph discovers folders through folder delta and creates one message
delta lane per folder. It requests immutable IDs for message operations, reads
raw MIME through `/$value`, treats a folder removal as a membership tombstone,
and validates opaque `nextLink` and `deltaLink` URLs against the configured
Graph HTTPS authority before following them. An expired delta cursor resets
only the affected lane.

Folder classification uses well-known Graph folder IDs rather than localized
display names. Reconciliation updates mapping metadata and historical remote
placement without replacing opaque cursor URLs or refetching raw MIME. Graph
Sent Items maps to the provider-neutral local Sent system folder.

Each job handles one bounded page. A cursor checkpoint occurs only after every
message represented by that page has been durably imported or idempotently
matched. Temporary provider errors snooze Styx work and honor numeric
`Retry-After`; reconnect errors stop the account until a new authorization is
completed.

The code inserts the first sync job with OAuth completion and can enqueue an
individual account manually. The local release starts a `connectors` Styx queue,
and a five-minute cron job inserts missing work for connected, syncing, or
failed accounts. Gmail watch and Microsoft Graph subscription/push delivery are
not implemented.

### 22.3 Durable provider import

Provider import is not an SMTP transaction:

- `InboundDelivery.source_kind` is `provider_import`.
- The provider account and message IDs form an idempotent external identity.
- The accepted raw and target-mailbox fingerprints detect conflicting repeats.
- The spool manifest records provider provenance and trusted destination IDs.
- SMTP peer IP, HELO, envelope sender, and original recipients remain absent.
- No `DeliveryRecipient` row is synthesized.

The ready spool bundle is renamed before the PostgreSQL acceptance transaction.
That transaction creates the inbound delivery, mailbox entry, accepted event,
archive job, and external-ingress identity together. A retry with the same
provider identity, bytes, and target mailbox returns the original receipt.
Different bytes or a different target under the same provider identity are a
permanent conflict.

After normal archival and projection, a separate idempotent job applies the
supported remote folder, read, starred, and deleted state through the public
Mail API. Remote deletion moves the local projection to trash; it never deletes
the immutable local raw message.

### 22.4 Current integration limits

- No provider push; recurring synchronization polls every five minutes.
- No Gmail or Microsoft remote mutation.
- No Graph draft creation, `Mail.ReadWrite`, optimistic Sent copy, or automatic
  retry of an uncertain Microsoft submission.
- A provider message disappearing between listing and raw fetch is normalized
  into an idempotent remote tombstone without deleting local immutable data.
- Microsoft folder membership removals probe the global message resource; an
  existing message is treated as a move and `404` as remote deletion.
- Development and production read OAuth client credentials from database-backed
  Settings → OAuth; legacy client-credential environment values are ignored.
  Production additionally requires a stable connector encryption key.

These limits keep receive synchronization isolated from provider mutation and
push lifecycle. Manifold never performs direct outbound MX delivery.

### 22.5 Account-selected outbound methods

Each account has at most one enabled Gmail, Microsoft, or SMTP send method.
Queueing freezes the method ID, provider, sender address, deterministic RFC
bytes, render version, bytes hash, and provider RFC `Message-ID`. Workers must
use that immutable snapshot and verify its hash before credential checkout or
network I/O; a settings or draft change never reroutes queued mail or changes
retry bytes. Legacy Resend rows retain their provider-only shape for
compatibility.

Gmail, Microsoft, and SMTP submissions are text-only and preserve `Date`,
`Message-ID`, `In-Reply-To`, and `References`. Gmail uses the exact connected
account identity and Gmail API `gmail.send`; Microsoft sends the exact persisted
MIME through direct `/me/sendMail` with `Mail.Send`; SMTP uses the account's
encrypted relay credential. HTML, attachments, aliases, and provider push are
follow-ups.

Gmail, Microsoft, and SMTP are non-idempotent once a remote endpoint may have
accepted the request. An ambiguous response, lost connection, or interrupted
`submitting` attempt transitions to `submission_uncertain`. Automatic resend is
disabled and manual reconciliation is required.

Gmail and Microsoft receive/send methods each share one provider-specific
authorization record, refresh token, scope union, and reconnect state. A
bodyless Microsoft `202` is immediate provider acceptance without a provider
message ID. Graph Sent Items imported by normal/manual polling is the
authoritative projected Sent copy; outbound Send activity remains a separate
lifecycle model. Deploying the shared-authorization migrations
is non-rolling: drain all old app instances, connector workers, and Oban workers
before migration. Migration `20260811000500` performs lossless rollback
preflights; `20260811000600` requires a unique legacy receive event anchor;
`20260811000700` guards Gmail/SMTP submissions; and the `20260812` Microsoft
authorization, Sent-folder, and payload migrations retain legacy Microsoft
cursors and encrypted-token associated data.

---

## 23. Testing Strategy

### 23.1 Unit tests

Cover pure behavior:

- Address parsing and normalization.
- Recipient and alias resolution.
- Plus addressing.
- State transitions.
- Provider event normalization.
- Storage key generation.
- SMTP error classification.

### 23.2 Property tests

Use property testing where it adds value:

- Normalization idempotence.
- Recipient-resolution determinism.
- Manifest encode/decode round trips.
- State machine transition validity.
- Untrusted filename isolation from storage paths.

### 23.3 Integration tests

Use a real PostgreSQL database and real temporary spool directories:

- SMTP transaction over TCP.
- Unknown recipient rejection at `RCPT TO`.
- Accepted delivery creates the exact expected records.
- Raw message bytes and digest are preserved.
- Styx archival succeeds and removes the ready bundle.
- Object-store failure retries without losing the bundle.
- Process restart resumes committed work.
- Webhook replay is idempotent.
- LiveView lists accepted deliveries through public context APIs.
- OAuth state, provider adapters, encrypted token rotation, bounded sync pages,
  idempotent provider import, and cursor reset use deterministic local HTTP
  fakes rather than live provider accounts.

### 23.4 Crash-boundary tests

Explicitly test failures:

1. Before raw file sync.
2. After raw sync but before atomic rename.
3. After ready rename but before database commit.
4. After database commit but before SMTP response.
5. During object-store upload.
6. After object-store upload but before database state update.
7. After archived state update but before spool cleanup.
8. After attachment blob storage but before projection commit.
9. After projection commit but before ingest processing-state update.
10. After archival commit but before the projection worker runs.

The expected recovery state must be documented for each boundary.

### 23.5 Fixture corpus

Maintain a safe mail fixture corpus containing:

- Plain text.
- HTML alternative.
- Multiple recipients.
- Nested multipart.
- Inline images.
- Attachments.
- Repeated headers.
- Missing or malformed `Message-ID`.
- Long folded headers.
- Invalid MIME boundaries.
- 8-bit body content.

Do not rely on live Internet services in the default test suite.

---

## 24. Release Milestones

### Milestone 0 — Repository and architecture

Implemented.

- Umbrella repository.
- Nix/devenv environment.
- PostgreSQL and Ecto.
- Styx.
- Phoenix LiveView shell.
- Architecture documentation and ADRs.
- Quality and CI commands.

### Milestone 1 — Durable inbound vertical slice

Implemented.

- Domain, mailbox, and alias configuration.
- Recipient resolver.
- SMTP listener on development port 2525.
- Durable spool bundle.
- PostgreSQL acceptance transaction.
- Transactional archival job.
- Local raw-store adapter.
- Minimal inbound-delivery LiveView.
- Recovery and crash-boundary tests.

### Milestone 2 — Mailbox projection

Implemented.

- MIME parser.
- Normalized message data.
- Text and safe HTML rendering.
- Attachments.
- Mailbox entries.
- Threading.
- Basic PostgreSQL search.
- Inbox, folder, and conversation navigation.
- Read, unread, starred, archive, move, and trash actions.

### Milestone 3 — Managed outbound

Implemented.

- Compose, drafts, reply, reply-all, and forward.
- Sent-mail views.
- Provider behaviour, account-selected Gmail API and authenticated SMTP
  adapters, and legacy Resend HTTPS compatibility.
- Outbound Styx queue.
- Authenticated raw-body provider webhooks.
- Per-recipient delivery, bounce, complaint, suppression, delay, and failure
  state.

### Milestone 4 — Security and policy

Implemented.

- SPF, DKIM, and DMARC evaluation.
- Rate-limit hardening.
- Quarantine.
- Malware/spam adapter integration.
- Operational dashboards.

Release 0.1 ships deterministic adapter contracts and explicit
`not_evaluated` defaults. DNS-backed authentication verification and production
scanner/classifier engines remain deployment integrations, not bundled network
services.

### Milestone 5 — Cloud ingress edge

Implemented.

- Separate edge release.
- Recipient route synchronization.
- Durable cloud spool.
- Local pull protocol.
- Idempotent acknowledgement.
- Edge operational UI/API.

### Milestone 6 — External connectors and optional client protocols

Implemented. The connector domain, migration, OAuth/credential primitives,
Gmail and Microsoft provider adapters, bounded sync engine, durable external
import, remote-state application, runtime configuration, local-release/Styx
wiring, polling, and no-auth account settings are implemented and verified.

- Read-only Gmail API receive synchronization.
- Read-only Microsoft Graph synchronization.
- Encrypted OAuth credentials and one-time PKCE transactions.
- Provider-message identity and resumable cursors.
- Durable raw import without fabricated SMTP metadata.
- Polling-based synchronization; provider push remains out of scope.

The Microsoft delivery extension implements account-selected Graph direct MIME
submission and provider-neutral projected Sent separated from outbound Send
activity. Credentialed staging verification remains operator work.

The Phoenix web application remains the primary client. External protocols and
connectors extend interoperability; they do not define the core user
experience. Read-only IMAP and EAS receive are implemented after the original
Milestone 6 scope; JMAP remains a future extension point.

### Explicit outbound TLS backend

`Manifold.Connectors.TLS` owns backend selection for outbound IMAP, authenticated
SMTP submission and EAS. OTP is the default; account-scoped operator configuration
or an explicit connection setting can select ex_ssl. The opaque handle records
the backend so all later operations dispatch consistently. Selection never
triggers fallback or replay after a failure. STARTTLS requires a completely
consumed positive response and rejects unexpected buffered plaintext.

Business HTTP consumers use native `http_fetch` through
`Manifold.Core.HTTPClient` with fresh HTTP/1 connections and no redirects or
transport replay. EAS.HTTPAdapter keeps request/TLS policy while native Fetch
owns response framing. EAS preserves verified peer identity, WBXML and bounded
request/response data. Published 0.21.10 fixes upstream #121 response-version
admission; #114/#115 DAV method/framing fixes are also included. See
[HTTP_CLIENT.md](HTTP_CLIENT.md) for the migration worktree, finite deadline
semantics and verification evidence.
Inbound/server/database TLS keep their existing transports. See [TLS_BACKENDS.md](TLS_BACKENDS.md) for the
acceptance contract, supported options and independently validated scope.

---

## 25. Release 0.1 Acceptance Criteria

Release 0.1 is acceptable when:

1. A local user can create a domain and mailbox.
2. An SMTP client can deliver a message to that mailbox.
3. Unknown recipients receive `550` during `RCPT TO`.
4. A successful `250` is never sent before durable spool and database commit.
5. The exact accepted raw message is recoverable as `.eml`.
6. A crash after acceptance does not lose the message.
7. Object-store outages do not lose accepted messages while spool capacity remains.
8. The webmail UI displays accepted and processed messages through inbox and message views.
9. Attachments are stored and downloaded safely.
10. Outbound mail is submitted through a managed provider, never directly to recipient MX servers.
11. Replayed provider webhooks are idempotent.
12. The default test suite covers protocol, persistence, retry, and crash boundaries.
13. Production secrets are runtime-configured and absent from the repository.
14. The repository is reproducible through its Nix/devenv environment.

---

## 26. Initial Architectural Decisions

The repository should record at least these ADRs:

1. **Inbound-first product boundary.**
2. **Managed provider for outbound delivery.**
3. **Persistent spool before SMTP acknowledgement.**
4. **PostgreSQL as metadata source of truth.**
5. **Raw RFC 5322 message as immutable source of truth.**
6. **Modular umbrella monolith.**
7. **Styx for durable asynchronous stages.**
8. **Storage behaviour with local and ESS/S3 adapters.**
9. **No IMAP, POP3, or direct outbound MTA in Release 0.1.**
10. **Future cloud edge uses local-initiated, idempotent synchronization.**


## Contacts and local calendars

The historical Release 0.1 contact/calendar non-goal is superseded by local
contact/calendar/event CRUD. Contacts retains an Account-owned iCloud connection
with encrypted app-specific credentials; the Account address and Apple login may
differ. Calendar connections are independent of Accounts and mail receive/send
methods. A local Calendar can bind multiple Google/iCloud targets without changing
its identity. Provider subjects/principals must be verified before reusing mappings.

Shared schemas and central migrations are owned by `manifold_data`;
`manifold_contacts` owns local contact CRUD/query contracts and
`manifold_calendars` owns local calendar/event CRUD, recurrence and timezone queries.
`manifold_connectors` owns Calendar coordination, Google and DAV transport, credentials and
generation/lease-fenced jobs. Web exposes
`/contacts`, `/calendars`, and Account configuration with existing trusted-local
authorization and DuskMoon themes. `/settings/icloud` is a compatibility list
linking to Accounts. Main includes these services; edge remains ingress-only.

Local saves commit revision/intention state before asynchronous writes. Contacts
need explicit Account ownership, sync opt-in, and a default writable address
book. Calendars work fully locally; each optional target requires a persisted
initial enrollment preview. Independently existing events are never merged by
UID/title/time. Accepted inbound edits/deletions produce canonical revisions and
fan out atomically; source echoes do not produce revisions. Conditional writes
have immutable component revision vectors. Acknowledgments cannot clear newer
edits, and unknown outcomes require read reconciliation before replay. Pausing or
detaching one target retains history and leaves other targets operational.
Account purge retains local calendars/events. Calendar queries expand bounded
RRULE/RDATE/EXDATE and detached exceptions; copy/delete commands have explicit
occurrence/series scope. Remote container management, invitation/RSVP flows and
future-series splits remain excluded.

Only complete validated collection results commit deletions/checkpoints. Each
service commits independently. Unknown or malformed projections retain previous
data. Credential replacement, disable/disconnect and expired/replaced sync
leases reject stale commits. Full setup and rollback guidance is in
[ICLOUD.md](ICLOUD.md) and [CALENDARS.md](CALENDARS.md). Migrated Calendar bindings
remain paused pending identity verification and a read-only comparison; legacy
resource counters never become invented per-component acknowledgments. Current
Calendar evidence is in [calendar-validation.md](superpowers/implementation/calendar-validation.md).
The separate credentialed Apple Contacts gate remains tracked in
[ICLOUD_ACCEPTANCE.md](ICLOUD_ACCEPTANCE.md); historical designs remain indexed
from [README.md](README.md).
