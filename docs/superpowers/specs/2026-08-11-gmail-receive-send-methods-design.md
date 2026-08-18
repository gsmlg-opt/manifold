# Gmail Receive and Send Methods Design

Date: 2026-08-11

## Goal

Make Gmail a fully operational account receive and send method. Preserve the
existing real Gmail API receive synchronization, add Gmail API submission with
the `gmail.send` OAuth scope, and route outbound messages through each account's
enabled send method. Make the existing SMTP send method operational in the same
router so every selectable send method has real delivery behavior.

## Product decisions

| Decision | Choice |
| --- | --- |
| Gmail send transport | Gmail API `users.messages.send` with OAuth |
| OAuth model | One shared Gmail authorization per Manifold account |
| Authorization growth | Incremental scopes: `gmail.readonly` and `gmail.send` |
| Gmail cardinality | One Gmail identity per Manifold account; many distinct Gmail identities per installation |
| Sender identity | Canonical connected Gmail address must exactly match the Manifold account address |
| Initial content | Plain text with To, Cc, Bcc, subject, `In-Reply-To`, and `References` |
| Ambiguous acceptance | Mark `submission_uncertain`; never retry automatically |
| Missing send method | Block sending and link to **Add send method** |
| Other send transport | Make existing SMTP methods operational |
| Resend | Remove the implicit global fallback |

## Scope

This feature changes:

- Gmail OAuth ownership and incremental authorization.
- Gmail receive-method persistence only as needed to reference shared OAuth.
- Account send-method persistence and selection.
- Outbound queueing, message rendering, provider dispatch, and retry behavior.
- Gmail API and SMTP submission adapters.
- Account settings and compose error/empty states.
- Operational documentation, architecture decisions, and feature references.

The existing Gmail history-based receive implementation, durable external
ingest boundary, raw-message storage, MIME projection, and security evaluation
remain unchanged after token acquisition.

## Out of scope

- Gmail push notifications or replacing the five-minute pull scheduler.
- Gmail label/read/star write-back.
- Gmail aliases or Google Workspace delegation.
- HTML composition, attachments, drafts stored in Gmail, or scheduled send.
- Delivery/bounce tracking beyond provider acceptance.
- Automatically retrying an ambiguous Gmail or SMTP submission.
- Microsoft Graph send.
- Direct recipient-MX delivery.

The Microsoft Graph send exclusion records this feature's 2026-08-11 scope; it
was superseded by the later Microsoft 365 receive/send implementation and ADR
0011.

## Architecture and ownership

Introduce a shared OAuth authorization owned by `manifold_connectors`:

```text
Manifold account
  `-- Gmail OAuth authorization
       |-- Gmail receive method -> gmail.readonly
       `-- Gmail send method    -> gmail.send
```

The authorization represents one Google identity permanently bound to one
Manifold account. It owns provider identity, granted scopes, encrypted tokens,
token expiry, connection status, and authorization errors. Receive and send
methods reference it independently.

`manifold_connectors` owns:

- OAuth state, PKCE, incremental scope requests, and callback validation.
- Provider identity binding and encrypted token persistence.
- Serialized access-token refresh.
- Receive-method and send-method configuration and lifecycle.
- A narrow internal API for resolving a submission method and checking out its
  usable credential material.

`manifold_outbound` owns:

- Selecting and snapshotting the enabled send method at queue time.
- Deterministic RFC message rendering.
- Gmail API and SMTP submission adapters.
- Provider error normalization, retry decisions, and outbound state.

Outbound code does not query or decrypt connector credential tables directly.
It uses the public Connectors boundary. Decrypted tokens and passwords are
short-lived process values and must never be logged or persisted in Oban args.

## Data model

### Shared OAuth authorizations

Add an OAuth authorization model with at least:

| Field | Purpose |
| --- | --- |
| `account_id` | Permanently bound Manifold account |
| `provider` | `gmail` in this implementation |
| `provider_subject_id` | Durable Google OpenID subject |
| `email_address` | User-visible provider address |
| `granted_scopes` | Normalized set returned by Google |
| `status` | `connected`, `reconnect_required`, or `disconnected` |
| encrypted access token | Versioned AES-256-GCM envelope |
| encrypted refresh token | Versioned AES-256-GCM envelope |
| `token_expires_at` | Access-token expiry |
| error fields | Last normalized authorization failure |
| lock/version fields | Refresh and concurrent-update safety |

Enforce:

- One authorization per `{account_id, provider}`.
- One binding per `{provider, provider_subject_id}` across the installation.
- A Gmail authorization address equal to the account's canonical address.

At the time of the shared-authorization migration, existing OAuth receive
credentials migrated into this model without changing method enabled state or
requiring reauthorization. That no-reauthorization promise is superseded by the
2026-08-18 OAuth provider-settings cutover: the first database-backed Google
credential save marks existing Gmail grants and methods reconnect-required.
Preserve the existing credential associated-data binding when possible; if
identifiers change, decrypt and re-encrypt inside the migration path rather than
copying ciphertext under a different authentication context.

Password credentials for IMAP, EAS, and SMTP remain purpose-bound password
secrets and are not converted into OAuth authorizations.

### Receive and send methods

Add a nullable OAuth authorization reference to Gmail receive and send methods.
Add `gmail` to the allowed send-method kinds. Keep the existing invariant of at
most one enabled receive method and one enabled send method per account.

The send method, not the authorization alone, controls whether outbound Gmail
submission is active. The shared authorization remains while either method
references it.

### Provider submissions

At queue time persist an immutable snapshot containing:

- Send method ID and kind.
- Provider name.
- Canonical sender address.
- Deterministic RFC `Message-ID`.
- Hash of the exact rendered RFC message.

The queued message remains bound to that send method. A later method switch
does not reroute it. Provider credentials remain live references so revocation
or disconnection can stop an unsent job.

## Gmail authorization flow

OAuth transactions record the requested purpose (`receive` or `send`) and the
required scope set.

### New Gmail receive method

1. If no Gmail authorization exists, request OpenID identity plus
   `gmail.readonly` using authorization code, PKCE, and offline access.
2. Verify the returned subject and canonical email address.
3. Create the shared authorization and enabled Gmail receive method.
4. Enqueue the existing initial synchronization job transactionally.

### New Gmail send method

1. If no Gmail authorization exists, request OpenID identity plus `gmail.send`.
2. If a receive-only authorization exists, incrementally request `gmail.send`
   while retaining the previously granted scopes.
3. Verify the subject, address, and complete required scope union.
4. Create and enable the Gmail send method, disabling the previous send method.

The receive flow behaves symmetrically when a send-only authorization already
exists. If the authorization already grants the needed scope, confirmation may
create the method without another Google consent round trip.

When Google omits a refresh token during an incremental grant, retain the
existing encrypted refresh token. When Google returns a replacement, update it
atomically with the access token and granted scopes.

The callback rejects, without creating or enabling a method:

- A canonical provider address different from the Manifold account address.
- A subject different from the account's existing Gmail authorization.
- A subject already bound to another Manifold account.
- A grant missing an existing or newly required scope.

Canonical equality trims and case-normalizes through the existing address
parser. It does not apply Gmail dot removal or plus-address equivalence.

## Settings experience

The existing **Add receive method** picker remains. Gmail stays visible but is
disabled as **Provider not configured** when operator OAuth credentials are
absent.

**Add send method** becomes a matching method picker:

- **Gmail** -- OAuth confirmation, upgrade, or reconnect path.
- **SMTP** -- existing host, port, TLS, username, and password form.

An existing receive-only Gmail account displays **Add Gmail send** or
**Upgrade Gmail access**. A revoked shared authorization displays one
**Reconnect Gmail** action and explains that both receive and send are paused.

Adding or enabling a method disables the previously enabled method only in the
same direction. Disconnecting Receive does not stop Send, and disconnecting
Send does not stop Receive.

## Compose and queueing

Draft creation and editing remain available without a send method. Queueing a
draft requires an enabled, connected, operational send method for the account.
If none exists, return `send_method_required`; the compose UI retains the draft
and links to **Add send method**.

Queueing must transactionally:

1. Lock the draft and account's enabled send method.
2. Validate that the draft sender matches the method and account address.
3. Render the exact plain-text RFC message.
4. Insert the provider submission snapshot, lifecycle event, and unique Oban
   job with the draft state transition.

Do not fall back to global Resend. Existing accounts without an enabled method
can continue reading and drafting but cannot send until configured.

## RFC message rendering

Gmail and SMTP use the same deterministic logical-message renderer with a
provider-specific delivery representation. Initial content contains:

- `From`, `To`, `Cc`, and `Bcc` input semantics.
- `Subject`.
- `Date`.
- A deterministic `Message-ID` derived from stable outbound identity.
- `In-Reply-To` and `References` when present.
- MIME version and a UTF-8 `text/plain` body with the required transfer
  encoding and CRLF normalization.

The SMTP wire message must not expose a `Bcc` header because Bcc recipients are
carried only in SMTP `RCPT TO` commands. The Gmail API derives To, Cc, and Bcc
recipients from the submitted raw message, so its request includes the Bcc
header and Google applies Bcc delivery semantics. Header values must reject or
sanitize CR/LF injection using existing address and composition validation.

Render the provider-specific bytes once per queued submission and persist their
content hash. Every definite retry for that submission uses identical bytes.

## Gmail submission

Implement a Gmail outbound adapter under the `manifold_outbound` provider
boundary:

1. Resolve the snapshotted Gmail method through Connectors.
2. Require a connected authorization with `gmail.send`.
3. Refresh the token under an authorization lock when needed.
4. Base64url-encode the exact RFC message.
5. POST it to `users.messages.send` for `userId=me`.
6. Persist Google's message and thread identifiers as provider metadata.

A successful Gmail response means `accepted_by_provider`; Gmail is responsible
for adding the message to Sent. Delivery and bounce status are not inferred.

Normalize Gmail errors:

| Condition | Class and behavior |
| --- | --- |
| Invalid/revoked grant | Reconnect; mark shared authorization and both methods `reconnect_required` |
| Missing `gmail.send` | Permanent for this attempt; offer authorization upgrade |
| Definite 429/5xx before acceptance | Temporary; honor `Retry-After` when present |
| Definite 4xx request rejection | Permanent |
| Transport loss where acceptance is impossible | Temporary |
| Transport loss after acceptance may have occurred | `submission_uncertain`; no automatic retry |

## SMTP submission

Extend the existing SMTP transport beyond connection testing:

1. Connect, greet, negotiate TLS, and authenticate using existing behavior.
2. Issue `MAIL FROM` for the account address.
3. Issue `RCPT TO` for every To, Cc, and Bcc recipient.
4. Send `DATA` only after every recipient is accepted.
5. Apply SMTP dot-stuffing and terminator rules to the exact RFC message.
6. Require a successful final server response, then send `QUIT` best-effort.

If any recipient is rejected before `DATA`, abort or reset the transaction and
do not deliver to the recipients already accepted at the RCPT stage. A 4xx
recipient response is temporary; a 5xx recipient response is permanent.

A connection loss before message acceptance is retryable. A loss after the
complete DATA body and terminator were transmitted but before a definitive
reply is `submission_uncertain` and is not retried automatically.

SMTP method creation continues to require a successful connection/auth test.
Its configured canonical email must match the Manifold account address.

## Shared authorization lifecycle

- Token refresh is serialized per authorization so receive sync and send jobs
  cannot refresh concurrently.
- Disconnecting one method removes or disables only that method.
- Disconnecting the final referencing method erases tokens and marks the
  authorization disconnected.
- Google `invalid_grant` or explicit revocation marks the shared authorization
  `reconnect_required`; both dependent methods stop.
- Reauthorization must bind the same Google subject and account address.
- Deleting an account cascades through methods, authorization, and secrets
  using the existing account deletion boundary.

Activity logs record authorization creation, scope upgrade, reconnect-needed,
method enable/disable/disconnect, and normalized submission outcomes. They must
not contain access tokens, refresh tokens, passwords, authorization codes, raw
messages, or full message bodies.

## Outbound retry and state semantics

The current generic provider idempotency window must not be applied blindly to
Gmail or SMTP. Neither transport provides Manifold's idempotency key as a
server-enforced deduplication contract.

- Definite pre-acceptance temporary errors use the existing Oban retry/backoff
  behavior.
- Definite permanent errors transition the message to failed.
- Ambiguous post-submission errors atomically transition the message and
  provider submission to `submission_uncertain` and complete/cancel the job.
- Manifold never automatically resends an uncertain message.
- A future explicit user retry must create a new submission decision and is
  outside this initial design.

## Multiple Gmail accounts

The installation may connect any number of distinct Gmail identities. Each is
isolated by Manifold account and authorization ID. Receive sync jobs, refresh
locks, send-method selection, activity logs, and provider submissions must use
those IDs rather than global Gmail state.

A Gmail identity already bound to one Manifold account cannot be reused by
another account. The subject binding is retained after final disconnect, so a
Manifold account can reconnect only that Gmail identity. Connecting a different
Gmail identity requires a distinct Manifold account (or deletion and explicit
recreation of the original account).

## Configuration and operations

Superseded by the 2026-08-18 OAuth provider settings design: this approved design
originally used `MANIFOLD_GMAIL_CLIENT_ID` and
`MANIFOLD_GMAIL_CLIENT_SECRET`, but current code ignores both variables and does
not import them. Current operators configure Google in Settings → OAuth; the
remaining callback requirements below still apply.

Operator documentation must cover:

- Enabling Gmail API in Google Cloud.
- Registering the exact HTTPS callback URI.
- Adding `gmail.send` to the consent-screen data access configuration.
- Test-user setup for non-production OAuth applications.
- Verification requirements before public production use.
- The stable connector encryption key requirement.

The former environment-pair startup validation is superseded. Current settings
require both fields on initial save, and a missing database setting keeps Gmail
visible but unavailable in both method pickers.

## Observability

Emit or extend telemetry around:

- OAuth start/callback/upgrade outcomes.
- Token refresh outcomes and duration.
- Send-method selection failures.
- Gmail and SMTP submission duration and normalized outcome.
- Definite retry, permanent failure, and uncertain submission counts.

Metadata may contain internal account, authorization, method, and outbound
message IDs plus adapter and error code. It must exclude credentials and
message content.

## Migration and compatibility

- Backfill existing Gmail receive connections into shared authorizations.
- Preserve existing receive status, enabled state, tokens, cursors, and jobs.
- Superseded by the 2026-08-18 provider-settings cutover: the original migration
  did not require existing receive-only Gmail users to reauthorize until they
  added Send or Google revoked the grant, but the first stored Google credential
  save now requires all existing Gmail grants to reconnect.
- Existing SMTP method records become real submission choices after deploy.
- Existing accounts without enabled send methods lose implicit Resend delivery
  and see the configuration link instead.
- Existing queued Resend submissions retain their snapshotted provider and may
  finish under the old adapter; only newly queued messages use account methods.

That last compatibility rule prevents a deployment from silently rerouting
already queued mail.

## Testing

### Data and context tests

- Backfill existing Gmail authorization and token data without changing receive
  state or invalidating credential authentication context.
- Enforce one provider authorization per account/provider and one account per
  provider subject.
- Permit distinct Gmail subjects on distinct Manifold accounts.
- Preserve an authorization while either method references it and erase tokens
  after the final disconnect.
- Keep the one-enabled-method invariant independently for receive and send.

### OAuth and Gmail adapter tests

- New receive-only and send-only grants.
- Incremental receive-to-send and send-to-receive upgrades.
- Existing refresh-token retention and returned refresh-token rotation.
- Subject mismatch, address mismatch, duplicate cross-account binding, and
  missing-scope rejection.
- Concurrent receive/send token refresh results in one refresh operation.
- Exact `users.messages.send` path, bearer token, base64url raw payload, response
  metadata, retry-after parsing, and error classification through `Req.Test`.

### SMTP tests

- TLS and STARTTLS authentication followed by complete submission.
- MAIL/RCPT/DATA ordering and Bcc envelope behavior.
- All recipients are accepted before DATA.
- CRLF normalization, dot-stuffing, and final terminator.
- Temporary and permanent recipient failures.
- Definite pre-acceptance disconnect versus ambiguous post-DATA disconnect.

### Outbound tests

- Draft queueing fails without an enabled send method and retains the draft.
- Queueing snapshots the enabled Gmail or SMTP method transactionally.
- Later method changes do not reroute queued work.
- Disconnecting a snapshotted method prevents unsent delivery.
- Gmail and SMTP use the same logical message fields while each submission
  retains stable provider-specific bytes and a content hash.
- Definite failures retry or fail according to class.
- Ambiguous outcomes become uncertain and never enqueue another automatic
  submission.
- Newly queued messages do not use global Resend; legacy queued Resend work may
  finish.

### Web tests

- Both method pickers keep unconfigured Gmail visible and disabled.
- Gmail send upgrade/reconnect actions use the correct account and purpose.
- SMTP creation remains asynchronous and becomes an operational method.
- Address mismatch and OAuth binding errors are visible without partial state.
- Compose links to **Add send method** when queueing is blocked.
- Multiple Manifold accounts render and operate on their own Gmail methods.

### Staging smoke test

CI uses fake Google and SMTP transports; it does not require real secrets. A
credentialed staging checklist must:

1. Connect two distinct Gmail identities to two matching Manifold accounts.
2. Receive mail into each account and verify isolation.
3. Incrementally add Gmail Send to each account.
4. Send from each account and verify the message appears in the correct Gmail
   Sent mailbox.
5. Submit one message through a configured SMTP account.
6. Verify an account without a send method is blocked with the setup link.

## Documentation updates during implementation

- Add an ADR that supersedes ADR 0007 only for provider outbound submission;
  Gmail receive remains read-only with respect to remote mailbox mutation.
- Update `docs/DESIGN.md` with shared OAuth authorization and account-selected
  outbound routing.
- Update operator configuration documentation for `gmail.send` and Google OAuth
  verification.
- Update `.agents/skills/develop/references/` with implementation ownership,
  operational behavior, and follow-ups.

## Acceptance criteria

1. Existing Gmail receive methods keep syncing after migration.
2. A receive-only Gmail authorization can add Send through incremental OAuth.
3. Distinct Manifold accounts can connect and use distinct Gmail identities.
4. A Gmail subject or mismatched address cannot be attached to the wrong
   account.
5. New outbound messages use the account's snapshotted enabled Gmail or SMTP
   method and never implicit Resend.
6. Gmail sends the deterministic plain-text RFC message through
   `users.messages.send` and records Google acceptance metadata.
7. SMTP performs complete authenticated submission with safe recipient and DATA
   handling.
8. Accounts without an enabled send method retain drafts and receive a setup
   link instead of sending.
9. Ambiguous Gmail and SMTP outcomes become `submission_uncertain` without an
   automatic resend.
10. Tokens, passwords, authorization codes, and message bodies are absent from
    logs, telemetry metadata, and job arguments.
11. Scoped connector, outbound, web, migration, formatting, and strict compile
    checks pass.
