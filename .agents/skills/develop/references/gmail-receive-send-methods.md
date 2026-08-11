# Gmail receive and send methods

## Feature

- **Date:** 2026-08-11
- **Status:** implemented; live-provider staging verification remains operator work
- **Architecture:** `docs/adr/0010-account-selected-outbound-methods.md`

## Module ownership

- `manifold_data` owns the shared authorization, receive/send method, credential,
  provider submission, and lifecycle-event schemas and migrations.
- `manifold_connectors` owns purpose-scoped OAuth, permanent Gmail subject/address
  binding, encrypted token rotation, shared reconnect state, send-method checkout,
  and SMTP credential checkout.
- `manifold_outbound` owns deterministic text RFC rendering, queue snapshots,
  Gmail API and SMTP adapters, attempt fencing, acceptance persistence, and
  uncertainty semantics. It retains legacy Resend compatibility.
- `manifold_web` owns Add receive/send method flows, incremental Gmail upgrade or
  reconnect actions, and the compose-time Add send method block.

## Schema and migrations

Primary schemas:

- `Manifold.Connectors.Schema.OAuthAuthorization`
- `Manifold.Connectors.Schema.ReceiveMethod`
- `Manifold.Connectors.Schema.SendMethod`
- `Manifold.Connectors.Schema.SendCredential`
- `Manifold.Connectors.Schema.SmtpSettings`
- `Manifold.Connectors.Schema.ConnectorEvent`
- `Manifold.Outbound.Schema.ProviderSubmission`
- `Manifold.Outbound.Schema.OutboundMessage`

Feature migrations:

- `20260811000100_add_shared_gmail_authorizations.exs` creates the shared OAuth
  authorization, links Gmail methods, adds OAuth purposes/scopes, snapshots send
  method IDs, and migrates legacy Gmail token material.
- `20260811000200_add_oauth_authorization_events.exs` allows connector lifecycle
  events to anchor to a shared authorization.
- `20260811000300_enforce_provider_submission_methods.exs` constrains provider
  values and requires Gmail/SMTP submissions to reference a matching method kind.

This is a non-rolling cutover. Drain and stop old Phoenix instances, connector
workers, and Oban workers before migrating, and start only the new release after
all migrations succeed. Migration `00100` refuses a down migration unless legacy
credentials can be restored losslessly; `00200` requires one legacy receive
anchor for each authorization event; `00300` refuses down while Gmail or SMTP
submissions exist.

## OAuth purposes and identity rules

- `purpose=receive` requires
  `https://www.googleapis.com/auth/gmail.readonly`.
- `purpose=send` requires `https://www.googleapis.com/auth/gmail.send`.
- A later purpose incrementally requests the stored scope union and uses the same
  authorization and refresh token.
- One Google `sub` is permanently bound to one Manifold account. Different
  Manifold accounts may connect different Gmail identities.
- The connected Gmail address must exactly match the canonical Manifold account
  address; Gmail plus or dot alias normalization is not used.
- Refresh and reconnect-required transitions serialize on the shared
  authorization and affect both Gmail directions.

## Queue and uncertainty invariants

- Queueing requires an enabled account send method and freezes `send_method_id`,
  provider, sender address, RFC `Message-ID`, and `request_sha256`.
- Workers never resolve a replacement method. They re-render deterministic bytes
  and compare the SHA before credential checkout or provider I/O.
- Gmail and SMTP attempts enter durable `submitting` state before the request.
  Attempt-count and state fences prevent stale results from overwriting newer or
  terminal state.
- Gmail and SMTP acceptance is non-idempotent. An interrupted attempt or
  ambiguous provider result becomes `submission_uncertain`; no automatic resend
  is allowed.
- Gmail reconnect marking must persist before its provider failure is committed.
- Legacy `provider = "resend"` rows retain their nil-method, expiring-idempotency
  shape and existing webhook lifecycle.
- Telemetry stop events contain only internal IDs, provider/method kind, adapter,
  outcome, normalized code, duration, and attempt count. Never add raw messages,
  bodies, headers, tokens, passwords, authorization codes, or provider error
  messages.

## Configuration

Required production secrets are `MANIFOLD_CONNECTOR_ENCRYPTION_KEY`,
`MANIFOLD_GMAIL_CLIENT_ID`, and `MANIFOLD_GMAIL_CLIENT_SECRET`. The encryption key
is Base64 for exactly 32 bytes and must remain stable. Enable the Gmail API,
configure the readonly and send scopes on the Google consent screen, register
`https://<host>/connectors/gmail/callback`, list test identities while the app is
in testing mode, and complete Google verification before public use.

## Scoped verification

```sh
devenv shell -- mix test apps/manifold_connectors/test/manifold/connectors/gmail_authorizations_test.exs \
  apps/manifold_connectors/test/manifold/connectors/oauth_test.exs \
  apps/manifold_connectors/test/manifold/connectors/submission_method_test.exs

devenv shell -- mix test apps/manifold_outbound/test/manifold/outbound/submission_test.exs \
  apps/manifold_outbound/test/manifold/outbound/provider/gmail_test.exs \
  apps/manifold_outbound/test/manifold/outbound/provider/smtp_test.exs

devenv shell -- mix test apps/manifold_web/test/manifold_web/account_live_test.exs \
  apps/manifold_web/test/manifold_web/external_accounts_web_test.exs \
  apps/manifold_web/test/manifold_web/outbound_mail_live_test.exs
```

Also run `mix format --check-formatted` and `mix compile --warnings-as-errors`
before release integration. Migration upgrade/rollback matrices and live-provider
smoke tests belong to the release verification task, not unit tests.

## Staging smoke checklist

- [ ] Confirm all old app, connector, and Oban workers are drained before migrate.
- [ ] Apply `00100`, `00200`, and `00300`; inspect constraints and migrated shared
      authorization rows without exposing ciphertext.
- [ ] Confirm Gmail API is enabled, consent scopes are configured, the exact HTTPS
      callback is registered, and the test identity is authorized for staging.
- [ ] Connect receive first, upgrade send, and verify one shared authorization and
      the exact account address; repeat send-first then receive-upgrade with a
      different Manifold/Gmail identity.
- [ ] Force token expiry in a controlled test account and verify one serialized
      refresh and shared reconnect state.
- [ ] Send a plain-text Gmail message and verify the provider copy and reply
      headers manually; do not claim this from automated tests.
- [ ] Send through the configured SMTP relay and verify acceptance manually.
- [ ] Simulate ambiguous Gmail and SMTP transport outcomes and verify
      `submission_uncertain` with no automatic second request.
- [ ] Confirm a compose attempt without a method preserves its draft and links to
      Add send method.
- [ ] Confirm legacy Resend lifecycle and webhook records remain readable.
- [ ] Exercise guarded down migrations only on disposable staging data and verify
      their documented refusal conditions.

## Follow-ups

- HTML composition and outbound attachments.
- Gmail and SMTP sender aliases.
- Microsoft Graph send.
- Gmail watch and Microsoft Graph subscription push optimization; polling remains
  the durable fallback.
