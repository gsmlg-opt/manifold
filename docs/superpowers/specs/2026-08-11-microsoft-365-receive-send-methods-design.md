# Microsoft 365 Receive and Send Methods Design

Date: 2026-08-11

## Goal

Make Microsoft 365 a complete account receive and send method without replacing
the production-shaped Microsoft Graph receiver that already exists. Preserve
the current delta-based raw-MIME receive path, move Microsoft credentials into
the shared OAuth authorization model established by the Gmail work, add
least-privilege Microsoft Graph MIME submission, and represent Microsoft's
authoritative Sent Items copy in a provider-neutral local Sent folder.

## Product decisions

| Decision | Choice |
| --- | --- |
| Provider | Microsoft Graph for Microsoft 365 work/school accounts |
| Receive transport | Existing folder and message delta polling |
| Send transport | Direct MIME `POST /me/sendMail` |
| Authorization | One shared Microsoft OAuth authorization per Manifold account |
| Permissions | Incremental delegated `Mail.Read` and `Mail.Send`; no `Mail.ReadWrite` |
| Sender identity | Connected Graph address must exactly match the canonical account address |
| Sent copy | Microsoft Sent Items is authoritative and enters Manifold through delta sync |
| Outbound lifecycle UI | Rename the existing outbound-only Sent screen to **Send activity** |
| Sent latency | Up to the existing five-minute poll interval, or a manual sync |
| Initial content | UTF-8 plain text with To, Cc, Bcc, subject, and reply headers |
| Ambiguous submission | Mark `submission_uncertain`; never retry automatically |
| Missing send method | Retain the draft and link to **Add send method** |
| Personal Microsoft accounts | Out of scope; the configured tenant remains `organizations` |

## Prerequisite and sequencing

This feature extends the generic authorization, send-method selection, MIME
rendering, and outbound routing foundation designed for Gmail. It must not add
a second Microsoft token store or another outbound router.

Before Microsoft implementation begins, the active Gmail feature branch must
be rebased onto current `main`. Its shared-authorization migration currently
uses version `20260811000100`, which conflicts with an existing migration on
`main`; the migration must be renumbered and reconciled with the newer account
purge and cleanup work.

The completed prerequisite must expose provider-neutral contracts for:

- Shared OAuth authorizations and purpose-scoped OAuth transactions.
- Independent receive and send methods that reference one authorization.
- Serialized token checkout and refresh.
- Transactional send-method snapshotting.
- Deterministic MIME rendering and uncertain-submission state.

## Scope

This feature changes:

- Microsoft OAuth ownership, scope upgrades, identity validation, and token
  refresh coordination.
- Microsoft receive-method persistence only as needed to reference shared
  authorization.
- Microsoft send-method persistence and settings workflows.
- Microsoft Graph outbound submission and provider error normalization.
- Graph folder classification so localized mailbox names do not determine
  system-folder semantics.
- The provider-neutral mail folder model to add Sent.
- Outbound provider-result persistence for a successful provider that returns
  no provider message ID.
- Immutable provider-payload persistence so a definite retry cannot render
  different MIME after a deployment.
- Migration, lifecycle cleanup, activity logs, telemetry, operator guidance,
  and focused tests for the affected applications.

## Out of scope

- Outlook.com personal Microsoft accounts or the `common`/`consumers` tenants.
- Microsoft Graph application permissions or administrator-wide mailbox access.
- `Mail.ReadWrite`, draft-then-send, or draft reconciliation.
- Graph change-notification subscriptions or webhook delivery.
- EAS, EWS, IMAP, or SMTP as the Microsoft 365 send transport.
- Aliases, shared mailboxes, delegated send-as, and send-on-behalf-of behavior.
- Remote read, star, move, or delete write-back through Graph.
- HTML composition, outbound attachments, scheduled send, and Graph drafts.
- Delivery, bounce, and complaint tracking after Microsoft accepts a message.
- Automatic or user-triggered resend of an uncertain submission.
- An optimistic local Sent copy.

## Existing receive boundary

The current `Manifold.Connectors.Provider.MicrosoftGraph` implementation is a
real receiver. It already provides:

- Authorization-code exchange and refresh-token rotation.
- `/me` identity lookup.
- Folder delta followed by one message-delta lane per folder.
- `Prefer: IdType="ImmutableId"` on Graph requests.
- Exact raw RFC message retrieval through `/me/messages/{id}/$value`.
- Opaque next/delta link validation against the configured Graph authority.
- Cursor-reset, throttling, reconnect, and permanent-error classification.

`Manifold.Connectors.Sync` already crosses `Manifold.Ingest.import_external/3`
before checkpointing a cursor. Normal spool acceptance, immutable raw storage,
MIME projection, attachment storage, and remote-state application remain
unchanged. This feature hardens folder discovery and authorization ownership;
it does not replace that receive pipeline.

## Architecture and ownership

```text
Manifold account
  `-- shared Microsoft OAuth authorization
       |-- Microsoft receive method
       |     `-- Graph delta -> raw MIME -> ingest -> projection
       `-- Microsoft send method
             `-- outbound snapshot -> deterministic MIME -> Graph sendMail
```

`manifold_connectors` owns:

- OAuth state, PKCE, purpose and requested-scope snapshots, and callbacks.
- Provider identity binding and encrypted token persistence.
- Serialized access-token checkout and refresh.
- Receive/send method configuration and shared-authorization lifecycle.
- Locale-independent Graph folder identity and receive synchronization.
- A narrow public API that returns usable short-lived credential material to an
  authorized internal caller.

`manifold_outbound` owns:

- Selecting and snapshotting the enabled send method at queue time.
- Deterministic logical-message and provider-specific MIME rendering.
- The Microsoft Graph submission adapter.
- Provider error normalization, retry decisions, submission uncertainty, and
  outbound lifecycle state.

`manifold_mail` owns:

- The provider-neutral Sent system-folder kind.
- Sent-folder creation, navigation, querying, and mailbox-entry placement.

`manifold_web` owns:

- Microsoft receive/send setup, scope-upgrade, reconnect, and error surfaces.
- Compose blocking when no operational send method exists.
- Sent-folder navigation and the existing manual synchronization action.
- The **Send activity** lifecycle surface and compatibility redirects from its
  former outbound-only Sent routes.

Outbound code must not query or decrypt connector credential tables directly.
Tokens exist only as short-lived process values and must never be persisted in
Oban arguments, outbound metadata, logs, or telemetry.

## Shared Microsoft authorization

Extend the provider-neutral OAuth authorization model with `microsoft`. A
Microsoft authorization contains at least:

| Field | Purpose |
| --- | --- |
| `account_id` | Permanently bound Manifold account |
| `provider` | `microsoft` |
| `provider_subject_id` | Stable Graph `/me` user ID |
| `email_address` | Verified canonical Graph address |
| `granted_scopes` | Normalized delegated scope set returned by Microsoft |
| `status` | `connected`, `reconnect_required`, or `disconnected` |
| encrypted access token | Versioned AES-256-GCM envelope |
| encrypted refresh token | Versioned AES-256-GCM envelope |
| `token_expires_at` | Access-token expiry |
| error fields | Last normalized authorization failure |
| lock/version fields | Concurrent refresh and update safety |

Enforce:

- One authorization per `{account_id, provider}`.
- One binding per `{provider, provider_subject_id}` across the installation.
- An authorization address equal to the Manifold account's canonical address.
- One enabled receive method and one enabled send method per account,
  independently.

Receive and send methods reference the same authorization but control their own
enabled state. Disconnecting one direction does not stop the other. Removing
the final referencing method erases token ciphertext and marks the authorization
disconnected. A revocation or unrecoverable refresh failure marks the shared
authorization `reconnect_required` and pauses both directions.

## OAuth flows

OAuth transactions persist their purpose (`receive` or `send`) and complete
required scope set. The provider requests:

```text
Receive: openid profile offline_access User.Read Mail.Read
Send:    openid profile offline_access User.Read Mail.Send
```

When an authorization already exists, the requested set is the union of its
granted scopes and the new method's required scopes.

### New receive method

1. If no authorization exists, request the Receive scope set using
   authorization code, PKCE S256, and offline access.
2. Load Graph `/me`, verify its stable ID and canonical address, and validate
   the complete returned scope set.
3. Persist the shared authorization and enabled receive method.
4. Create the initial cursors and first unique sync job transactionally.

### New send method

1. If no authorization exists, request the Send scope set.
2. If a receive-only authorization exists, incrementally request `Mail.Send`
   while retaining the previously granted scopes.
3. Reverify the same Graph subject, canonical address, and complete scope union.
4. Create and enable the Microsoft send method, disabling only the previously
   enabled send method for that account.

The receive flow behaves symmetrically when a send-only authorization exists.
If all required scopes are already granted, method confirmation may proceed
without another Microsoft consent round trip.

When an incremental token response omits a refresh token, retain the existing
encrypted refresh token. When Microsoft returns a replacement, rotate it
atomically with the access token, expiry, and granted scopes.

The callback creates or enables nothing when:

- The provider address differs from the canonical Manifold account address.
- The Graph subject differs from the existing authorization.
- The Graph subject is already bound to another Manifold account.
- The grant omits an existing or newly required scope.
- The account is no longer active at callback time.

## Token checkout and refresh

Receive sync and send jobs share one authorization, so refresh must be
serialized per authorization:

1. Lock the authorization and re-read its status and expiry.
2. Return the current access token when it is still usable.
3. Otherwise decrypt the refresh token, refresh once, validate the returned
   scope set, and atomically rotate credential material.
4. Return a short-lived access token value after the transaction.

Concurrent receive and send callers must converge on one refresh request. An
`invalid_grant` or equivalent reconnect error updates authorization state before
the caller receives the normalized failure.

## Sent system folder

Add `sent` to the provider-neutral system-folder model. Every mailbox has
exactly one Inbox, Archive, Sent, and Trash system folder. Migration creates a
missing Sent row for every existing mailbox without moving existing entries.

Update folder creation, system-folder lookup, sorting, mailbox navigation,
external-state validation, and connector folder-kind normalization to support
`sent`. Include Sent in previous-folder restoration rules so moving a Sent
entry to Trash and restoring it returns the entry to Sent. Sent entries retain
the same archive/trash actions as other projected messages; no provider
write-back is introduced.

The model is reusable by other providers, including Gmail's `SENT` label, but
changing other provider mappings is not required for Microsoft acceptance.

## Locale-independent Graph folder mapping

The current adapter classifies folders by English `displayName`, which fails on
localized mailboxes. Graph v1.0 folder-delta objects do not identify their
well-known name, so bootstrap must resolve the concrete IDs through explicit
token-authenticated requests to:

```text
GET /me/mailFolders/inbox?$select=id
GET /me/mailFolders/archive?$select=id
GET /me/mailFolders/deleteditems?$select=id
GET /me/mailFolders/sentitems?$select=id
```

Perform the independent lookups concurrently. Inbox, Deleted Items, and Sent
Items are required for a usable Microsoft receive method; a missing required
folder fails bootstrap without creating or advancing cursors. Archive is
optional: a `404` omits that special mapping and other visible folders continue
to use local Archive. Authentication, throttling, and transport failures use the
normal provider classification and retry rules.

Persist the resulting ID-to-kind map plus a mapping schema version in the
folder-discovery `SyncCursor.metadata`; copy the resolved kind into each
per-folder cursor's metadata. Resolve it when creating initial cursors, on the
first upgraded sync whose metadata lacks the current mapping version, after a
folder cursor reset, and after reconnect. Do not infer or persist a system kind
from `displayName`.

Classify delta-discovered folders by the persisted ID map:

| Microsoft well-known folder | Local kind |
| --- | --- |
| `inbox` | `inbox` |
| `archive` | `archive` |
| `deleteditems` | `trash` |
| `sentitems` | `sent` |
| Other visible folders | `archive` |

Folder display names remain presentation metadata only. The provider boundary's
initial-cursor operation must use its access token for the bootstrap calls
rather than constructing a token-free cursor. Initial delta URLs use explicit
`$select` fields and a bounded page-size preference. Continuation and delta URLs
remain opaque, authority-validated values supplied by Graph.

After resolving the well-known IDs, update matching cursor metadata and
idempotently reapply local folder state for existing remote-message mappings
whose stored folder ID now has a different system kind. This moves previously
misclassified localized Inbox/Trash entries and historical Sent Items to the
correct local system folder without resetting delta cursors, refetching raw
MIME, or guessing from display names.

Messages continue to use immutable IDs and explicitly request only the fields
needed for identity, parent folder, conversation, receive time, read state, and
flag state. A page advances only after every actionable raw message crosses the
durable local acceptance boundary. Cursor expiry performs the existing
non-destructive reconciliation rather than deleting accepted history.

## Settings experience

The existing Add receive method picker remains. Microsoft stays visible but is
disabled as **Provider not configured** when operator OAuth credentials are
absent.

Add send method offers **Microsoft 365** alongside the other operational send
methods. Its state is one of:

- **Connect Microsoft** when no authorization exists.
- **Add Microsoft Send** or **Upgrade Microsoft access** when the authorization
  lacks `Mail.Send`.
- **Connected** when the method is enabled and authorization is usable.
- **Reconnect Microsoft** when the shared authorization needs consent again.

Reconnect is a shared action and explains that Receive and Send are paused.
Disabling or disconnecting a method affects only its own direction unless it is
the final authorization reference.

Sent appears beside Inbox, Archive, and Trash and lists projected mailbox
entries from `manifold_mail`. The current outbound-only Sent surface is renamed
**Send activity** and continues to list queued, accepted, failed, and uncertain
records from `manifold_outbound`. These are separate views and are not merged or
deduplicated.

Use `/mail/:mailbox_id/send-activity` and
`/mail/:mailbox_id/send-activity/:outbound_message_id` for lifecycle records.
The old outbound detail route `/mail/:mailbox_id/sent/:outbound_message_id`
redirects to its Send activity equivalent. `/mail/:mailbox_id/sent` resolves or
redirects to the mailbox's projected Sent system folder, so existing Sent
navigation retains the expected mailbox meaning without rendering a duplicate
folder item.

After Microsoft accepts a message, queueing navigates to its Send activity
detail and displays provider acceptance immediately. When Microsoft Receive is
enabled, the mailbox copy appears in Sent after the next scheduled or manual
delta synchronization. A send-only Microsoft method has no Graph receive
cursor, so its provider Sent copy remains visible in Microsoft but is not
imported locally until Microsoft Receive is added.

## Compose and queueing

Draft creation and editing remain available without a send method. Queueing
requires an enabled, connected Microsoft send method whose authorization grants
`Mail.Send`. If no operational method exists, return `send_method_required`,
retain the draft, and link to **Add send method**.

Queueing transactionally:

1. Locks the draft, account, and enabled send method.
2. Validates that the sender equals the account and authorization address.
3. Renders the exact provider-specific MIME bytes.
4. Persists the immutable send-method snapshot, provider, canonical sender,
   deterministic RFC `Message-ID`, render version, exact MIME payload, and
   payload hash.
5. Inserts the lifecycle event and unique Oban job with the draft transition.

After queueing, the Web flow navigates to the new Send activity detail route;
it does not claim that a projected Sent entry exists before delta sync.

A queued message remains bound to that method even if account settings later
change. Credentials remain a live reference so revocation can stop unsent work.
New messages never fall back to global Resend. Existing queued Resend work keeps
its original provider and may finish after deployment.

### Provider submission snapshot

The provider submission owns an immutable rendered-payload field or immutable
blob reference in addition to its SHA-256 hash. The exact storage mechanism is
shared with Gmail and SMTP, but it must be a dedicated payload boundary rather
than provider JSON metadata or an Oban argument. The snapshot also contains the
send method ID and kind, provider, canonical sender, deterministic Message-ID,
and render version. Microsoft provider message ID remains nullable; sanitized
request-correlation values use a separate metadata field.

## MIME rendering

Microsoft uses the same logical-message renderer established for Gmail and
SMTP. Initial MIME contains:

- `From`, `To`, `Cc`, and `Bcc` semantics.
- `Subject` and `Date`.
- A deterministic RFC `Message-ID` derived from stable outbound identity.
- `In-Reply-To` and `References` when present.
- MIME version and a UTF-8 `text/plain` body.
- Required transfer encoding and CRLF normalization.

Graph derives MIME recipients from To, Cc, and Bcc headers, so the submitted
Microsoft payload includes Bcc. Header inputs must reject CR/LF injection
through existing address and composition validation.

Render once at queue time. Every definite retry loads the identical immutable
payload representation; deployment of a new renderer must not change bytes for
already queued submissions.

## Microsoft Graph submission

Implement a Microsoft adapter under the `manifold_outbound` provider boundary:

1. Resolve the snapshotted Microsoft method through the Connectors API.
2. Require a connected authorization with `Mail.Send`.
3. Check out or refresh a usable access token under the authorization lock.
4. Base64-encode the exact MIME representation.
5. `POST /me/sendMail` with bearer authorization and `Content-Type: text/plain`.
6. Leave the default Sent Items behavior enabled.
7. Persist Microsoft request-correlation metadata when returned.

Successful Microsoft submission returns `202 Accepted` with no response body.
It means Microsoft accepted the request for processing; it does not prove final
delivery. `provider_message_id` must therefore be nullable for providers that do
not return a message identifier. A Microsoft request ID or client request ID is
diagnostic metadata and must not be treated as an idempotency key.

## Sent-copy convergence

Do not create an optimistic local mailbox message after `202`. Microsoft owns
the Sent Items copy. When Microsoft Receive is enabled, the normal message delta
observes that item, fetches its raw MIME, and crosses the existing durable
import boundary with its immutable Graph message ID. Its resolved folder ID
places the projected entry in Sent. Send-only accounts retain immediate
outbound status but do not import the provider copy until they add Microsoft
Receive.

The same external-ingress uniqueness that protects receive replay prevents two
imports of the same Graph Sent item. The outbound record and projected Sent
entry remain distinct records in v1; no direct database relationship is
required. Absence of the Sent copy during the normal Graph processing delay does
not change accepted state and never triggers a resend.

## Failure and retry semantics

| Condition | Classification and behavior |
| --- | --- |
| `202 Accepted` | `accepted_by_provider`; do not infer delivery |
| Explicit `429` | Temporary; honor `Retry-After` and retry identical bytes |
| DNS/TCP/TLS failure proven before dispatch | Temporary |
| Any `5xx` in v1 | `submission_uncertain` unless a documented response contract proves non-acceptance |
| Connection loss after Graph may have received the request | `submission_uncertain`; no automatic retry |
| Invalid/revoked grant | Mark shared authorization `reconnect_required`; pause both methods |
| Missing `Mail.Send` | Permission upgrade required; do not retry this attempt |
| Invalid MIME, sender, or recipient request | Permanent failure |
| Tenant or mailbox policy rejection | Permanent method failure with a safe user-visible reason |
| Sent copy not yet visible | Keep accepted state and wait for normal/manual sync |

The transport boundary must expose whether a failure is provably pre-dispatch.
When it cannot prove that Graph did not receive the request, choose uncertainty.
Microsoft Graph does not enforce Manifold's deterministic `Message-ID` or
submission ID as an idempotency contract. Microsoft does not document a general
`5xx` guarantee that the mail pipeline was not entered, so v1 does not
automatically retry `5xx` responses. A future status-specific retry may be added
only with a cited Microsoft guarantee and a regression test proving the safe
classification.

An uncertain submission atomically updates the outbound message and provider
submission, completes or cancels its job, and cannot be automatically retried.
An explicit user resend/resolution workflow remains outside this feature.

## Authorization lifecycle

- Refresh is serialized across receive and send.
- Disabling one method does not disable the other.
- Disconnecting the final method erases credential ciphertext.
- `invalid_grant` and unrecoverable authentication failures mark the shared
  authorization `reconnect_required`.
- Reauthorization must bind the same Graph subject and canonical address.
- Account suspension stops new sync and send work through existing lifecycle
  fences.
- Account purge/deletion removes both methods, authorization, credentials,
  cursors, jobs, logs, and provider-specific residues through the existing
  account-deletion boundary.

## Security invariants

- Use delegated Microsoft 365 work/school permissions only.
- Request `Mail.Read` and `Mail.Send`, never `Mail.ReadWrite`, for this feature.
- Preserve PKCE S256, one-time state digest, exact redirect URI, and trusted
  HTTPS authority validation.
- Require the connected Graph address to equal the canonical account sender.
- Keep access/refresh tokens and authorization codes out of job arguments,
  provider metadata, logs, telemetry, and UI error details.
- Keep MIME, bodies, addresses, and Bcc recipients out of logs and telemetry.
- Store the immutable MIME payload only in its dedicated outbound payload
  boundary; never duplicate it into provider metadata or job arguments.
- Treat continuation URLs, provider error strings, and response metadata as
  untrusted input before storage or presentation.
- Require the stable connector encryption key in every environment that stores
  OAuth credentials.

## Configuration and operations

Continue using the existing Microsoft configuration:

- `MANIFOLD_MICROSOFT_CLIENT_ID`
- `MANIFOLD_MICROSOFT_CLIENT_SECRET`
- `MANIFOLD_MICROSOFT_TENANT`, defaulting to `organizations`
- Existing Microsoft authorization, token, Graph base, and callback endpoints
- `MANIFOLD_CONNECTOR_ENCRYPTION_KEY`

Only a complete client ID/secret pair enables Microsoft. A partial pair must
fail startup; an absent pair leaves the provider visible but unavailable.

Operator documentation must cover:

- Registering the exact HTTPS callback URI.
- Enabling delegated `User.Read`, `Mail.Read`, and `Mail.Send` permissions.
- Tenant consent policy and user-consent restrictions.
- Incremental consent for existing receive-only accounts.
- Stable encryption-key backup and rotation constraints.
- Staging smoke-test setup with non-production Microsoft identities.
- Expected polling and Sent-copy delay.

## Observability

Emit or extend telemetry for:

- OAuth start, callback, scope upgrade, and rejection outcomes.
- Token refresh outcomes and duration.
- Well-known folder resolution and sync outcomes.
- Send-method selection failures.
- Microsoft submission duration and normalized outcome.
- Definite retry, permanent failure, reconnect, and uncertainty counts.

Activity logs record authorization creation, scope upgrade, reconnect-needed,
method enable/disable/disconnect, and normalized submission outcomes. Metadata
may contain internal account, authorization, method, cursor, outbound message,
and submission IDs plus sanitized Graph error and request codes. It must exclude
credentials, codes, MIME, addresses, recipients, subjects, and bodies.

## Migration and compatibility

The implementation sequence is:

1. Rebase and renumber the Gmail shared-authorization migration.
2. Reconcile shared-authorization cleanup with current account lifecycle work.
3. Extend authorization/send-method provider constraints with `microsoft`.
4. Backfill Microsoft OAuth rows into shared authorizations.
5. Attach existing Microsoft receive methods to those authorizations.
6. Add Sent to folder constraints and create one missing Sent folder per
   mailbox.
7. Extend provider-submission persistence for immutable MIME payloads and
   bodyless Graph acceptance.
8. On the first post-deploy Microsoft sync, reconcile existing remote-message
   folder kinds from resolved well-known IDs without resetting cursors.

Existing token ciphertext is authenticated with associated data derived from
legacy identifiers. Preserve the compatible identifier when moving it into the
authorization model, as the Gmail migration does. If that is impossible after
the rebase, decrypt and re-encrypt transactionally; never copy ciphertext under
new associated data.

Migration must preserve:

- Receive enabled/status state.
- Provider subject and email identity.
- Access/refresh tokens, expiry, and granted scopes.
- Folder/message delta cursors and queued sync jobs.
- Existing remote-message mappings and imported history.
- Existing queued Resend submissions and their provider snapshots.

Existing Microsoft receive-only accounts are not reauthorized during deploy.
They request `Mail.Send` only when the user adds Microsoft Send.

## Testing

### Data and lifecycle tests

- Backfill Microsoft authorizations without changing receive state or breaking
  encrypted credential authentication.
- Preserve cursors, jobs, mappings, and provider identity.
- Enforce one account/provider authorization and one account per Graph subject.
- Keep receive/send enabled invariants independent.
- Retain authorization while either method references it and erase secrets
  after the final disconnect.
- Create exactly one Sent folder for every existing and new mailbox.
- Restore a trashed Sent entry to Sent rather than Inbox or Archive.
- Include Microsoft authorization and Sent data in suspension/purge coverage.

### OAuth and credential tests

- New receive-only and send-only grants.
- Receive-to-send and send-to-receive incremental upgrades.
- Existing refresh-token retention and returned refresh-token rotation.
- Subject mismatch, address mismatch, duplicate binding, inactive account, and
  missing-scope rejection.
- Concurrent receive/send token checkout performs one refresh.
- Revocation marks both dependent methods unavailable.

### Receive tests

- Well-known folder IDs map correctly when display names are localized.
- Sent Items maps to local Sent; custom folders map to Archive.
- Existing mappings misclassified by localized display names are moved locally
  without raw refetch or cursor reset.
- An upgraded account with committed folder/message delta links repairs cursor
  metadata and historical Sent placement without replaying accepted raw mail.
- Initial URLs request bounded pages and explicit fields.
- Existing immutable ID, authority validation, pagination, cursor-reset,
  replay, raw-MIME import, move, and deletion tests remain green.
- A Graph Sent item is imported once and placed in Sent.

### Graph submission tests

- Exact `/me/sendMail` path, bearer token, `Content-Type`, and base64 MIME body.
- To/Cc/Bcc, subject, date, deterministic Message-ID, reply headers, UTF-8,
  transfer encoding, and CRLF normalization.
- Successful bodyless `202` with optional request-correlation headers.
- Explicit 429 retry and `Retry-After` behavior.
- `5xx` and ambiguous post-dispatch transport failures become uncertain unless
  a testable provider contract proves non-acceptance.
- Invalid grant, missing scope, policy rejection, malformed MIME, and permanent
  request classification.
- Provable pre-dispatch failure versus ambiguous post-dispatch transport loss.
- Uncertain submission never schedules another automatic attempt.

### Outbound tests

- Queueing fails without an operational send method and retains the draft.
- Queueing snapshots the enabled Microsoft method transactionally.
- Later method changes do not reroute queued work.
- Revocation prevents unsent work from checking out a token.
- Retries use identical MIME bytes and payload hash.
- A send-only method records outbound acceptance without claiming a local Sent
  copy; adding Microsoft Receive enables later Sent convergence.
- Newly queued Microsoft work never falls back to Resend.
- Legacy queued Resend work may finish.

### Mail and Web tests

- Sent is created, sorted, rendered, queried, and navigated as a system folder.
- Sent renders projected mailbox entries while Send activity renders outbound
  lifecycle records; the navigation contains no duplicate Sent label.
- New Send activity list/detail routes work, and legacy outbound Sent detail
  routes redirect without losing the selected message.
- Microsoft remains visible and disabled when unconfigured.
- Add Send performs scope upgrade for the correct account.
- Reconnect explains its shared Receive/Send impact.
- Compose links to Add send method without discarding the draft.
- Accepted outbound status is immediate while Sent convergence is eventual.
- Safe OAuth and provider errors are actionable without exposing secrets or
  message data.

### Staging smoke test

CI uses fake Graph transports and no real secrets. A credentialed staging test
must:

1. Connect two distinct Microsoft 365 work/school identities to two matching
   Manifold accounts.
2. Receive new, moved, and deleted mail with localized folder display names.
3. Verify account isolation and exact raw-MIME projection.
4. Incrementally grant `Mail.Send` to both accounts.
5. Send plain-text messages from each account, including Cc and Bcc.
6. Confirm accepted status appears immediately.
7. Trigger or await delta sync and confirm each authoritative copy appears once
   in the correct local Sent folder.
8. Revoke one grant and verify both methods pause only for that account.
9. Verify logs, activity files, telemetry, and Oban arguments contain no secret
   or message content.

## Microsoft API references

- [Send mail with MIME and delegated `Mail.Send`](https://learn.microsoft.com/en-us/graph/api/user-sendmail?view=graph-rest-1.0)
- [Get incremental message changes per folder](https://learn.microsoft.com/en-us/graph/delta-query-messages)
- [Mail folder resource and well-known folder names](https://learn.microsoft.com/en-us/graph/api/resources/mailfolder?view=graph-rest-1.0)
- [Outlook immutable identifiers](https://learn.microsoft.com/en-us/graph/outlook-immutable-id)
- [Microsoft Graph throttling guidance](https://learn.microsoft.com/en-us/graph/throttling)
- [Microsoft Graph permissions reference](https://learn.microsoft.com/en-us/graph/permissions-reference)

## Documentation updates during implementation

- Add an ADR that permits provider outbound submission while retaining the
  read-only receive boundary.
- Update `docs/DESIGN.md` for shared OAuth authorization, Sent, and
  account-selected provider routing.
- Update operator configuration documentation for `Mail.Send`, incremental
  consent, and expected Sent delay.
- Keep `.agents/skills/develop/references/microsoft-365-receive-send-methods.md`
  current with implementation ownership, validation, and follow-ups.

## Acceptance criteria

1. Existing Microsoft receive methods continue syncing after migration without
   reauthorization or cursor reset.
2. Localized Microsoft system folders map by well-known ID rather than display
   name, including idempotent repair of existing local placement.
3. Every mailbox has exactly one usable Sent system folder.
4. A receive-only Microsoft authorization can add Send through incremental
   `Mail.Send` consent without gaining `Mail.ReadWrite`.
5. Distinct Manifold accounts can connect distinct Microsoft identities, while
   subject or canonical-address mismatches are rejected.
6. New outbound mail uses the account's snapshotted Microsoft method and never
   implicit Resend.
7. Graph receives the deterministic plain-text MIME through `/me/sendMail` and
   a bodyless `202` records provider acceptance without claiming delivery.
8. Only explicit 429 and provable pre-dispatch failures retry with identical
   bytes; `5xx` and other ambiguous submissions become `submission_uncertain`
   and are never automatically resent.
9. When Microsoft Receive is enabled, Microsoft's authoritative Sent Items copy
   appears exactly once in the local Sent folder through normal or manual delta
   synchronization; send-only accounts do not claim local convergence.
10. Sent contains projected provider mail, while the separately named Send
    activity surface retains outbound lifecycle status and legacy route
    compatibility without merging the two models.
11. Revocation pauses both Microsoft methods and exposes one safe reconnect
    path; disconnecting one healthy method leaves the other operating.
12. Tokens, authorization codes, MIME, addresses, recipients, subjects, and
    bodies are absent from logs, telemetry, provider metadata, and job args.
13. Scoped data, connector, outbound, mail, and web tests plus formatting and
    strict compilation pass.
