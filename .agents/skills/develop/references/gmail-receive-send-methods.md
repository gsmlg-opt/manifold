# Gmail receive and send methods

## Feature

- **Date:** 2026-08-11
- **Status:** implemented; live-provider staging verification remains operator work
- **Architecture:** `docs/adr/0010-account-selected-outbound-methods.md`

## Module ownership

- `manifold_data` owns `Manifold.Repo`, database migrations, and shared database
  runtime configuration; it does not own domain schemas from other apps.
- `manifold_connectors` owns its shared authorization, receive/send method,
  credential, SMTP settings, and connector-event schemas, plus purpose-scoped
  OAuth, permanent Gmail subject/address binding, encrypted token rotation,
  shared reconnect state, method checkout, and the database-backed Google OAuth
  provider setting/resolver.
- `manifold_outbound` owns its outbound message, recipient, provider submission,
  and outbound-event schemas, plus deterministic text RFC rendering, queue
  snapshots, Gmail API and SMTP adapters, attempt fencing, acceptance
  persistence, and uncertainty semantics. It retains legacy Resend compatibility.
- `manifold_web` owns Add receive/send method flows, incremental Gmail upgrade or
  reconnect actions, the compose-time Add send method block, Settings → OAuth at
  `/settings/oauth`, and Gmail help at `/settings/oauth/gmail/help`.

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

- `20260811000500_add_shared_gmail_authorizations.exs` creates the shared OAuth
  authorization, links Gmail methods, adds OAuth purposes/scopes, snapshots send
  method IDs, and migrates legacy Gmail token material. Before any DDL it refuses
  legacy Gmail data containing more than one row per Manifold account or an
  address that does not canonically equal the account address; operators must
  resolve those records explicitly rather than relying on destructive guessing.
- `20260811000600_add_oauth_authorization_events.exs` allows connector lifecycle
  events to anchor to a shared authorization.
- `20260811000700_enforce_provider_submission_methods.exs` constrains provider
  values and requires Gmail/SMTP submissions to reference a matching method kind.
- `20260818000100_add_oauth_provider_settings.exs` creates the generic
  `connector_oauth_provider_settings` table and adds the provider-setting UUID and
  lock-version fence to OAuth transactions. Its down migration refuses while a
  setting or fenced transaction exists.

This is a non-rolling cutover. Drain and stop old Phoenix instances, connector
workers, and Oban workers before migrating, and start only the new release after
all migrations succeed. Migration `00500` refuses a down migration unless legacy
credentials can be restored losslessly; `00600` requires one legacy receive
anchor for each authorization event; `00700` refuses down while Gmail or SMTP
submissions exist. Migration `20260818000100` does not backfill environment
credentials and refuses down while settings or fenced OAuth transactions exist.
After that migration Gmail remains unavailable until Settings → OAuth is saved,
and every existing Gmail grant requires reconnect.

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
- Encryption uses context-bound associated data: shared Gmail tokens bind the
  authorization ID plus access/refresh kind, while PKCE verifiers bind provider
  plus account ID.
- OAuth start snapshots the current Google setting UUID and `lock_version`.
  Completion rejects a changed generation before exchange, performs provider I/O
  without a database lock, then takes the provider advisory lock and revalidates
  the generation in the final persistence transaction.
- `Manifold.Connectors.ProviderConfig` is the single resolver for Gmail provider
  discovery, OAuth start/exchange, refresh, receive sync, send-method checkout,
  and submission. It reads the current setting per operation, so changes take
  effect without restart.

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
- A Gmail rejection against a stale access-token generation is definitively
  unaccepted and returns to the retryable queue so the worker checks out the
  current token; a current-generation rejection marks the shared authorization
  and all Gmail methods `reconnect_required` before permanently failing the
  message. `insufficient_scope` follows the current-generation path so account UI
  always exposes a reconnect action.
- Account settings enable/disconnect operations require both the Manifold account
  ID and send-method ID at the Connectors transaction boundary. Client-supplied
  method IDs cannot mutate another account or erase its shared Gmail tokens.
- Legacy `provider = "resend"` rows retain their nil-method, expiring-idempotency
  shape and existing webhook lifecycle.
- Telemetry stop events contain only internal IDs, provider/method kind, adapter,
  outcome, normalized code, duration, and attempt count. Never add raw messages,
  bodies, headers, tokens, passwords, authorization codes, or provider error
  messages.
- OAuth start/complete/refresh use `[:manifold, :connectors, :oauth, ..., :stop]`;
  selection failures use `[:manifold, :outbound, :send_method, :select, :stop]`;
  provider attempts use `[:manifold, :outbound, :submit, :stop]`.
- Rescued database failures and unexpected exceptions emit one sanitized stop
  event; unexpected exceptions are then reraised unchanged. Submission telemetry
  exposes only a bounded set of known error codes and maps all others to
  `provider_error`.
- Missing Google settings surface `provider_not_configured`; corrupt stored
  credentials surface the sanitized `provider_configuration_error` telemetry
  code. Secrets and ciphertext must not appear in browser HTML, socket assigns,
  logs, telemetry, activity events, or error details.

## Configuration

`MANIFOLD_CONNECTOR_ENCRYPTION_KEY` remains the required, stable, out-of-database
master key and is Base64 for exactly 32 bytes. Configure the Google client ID and
secret at `/settings/oauth`; the client ID is plaintext and the client secret is
encrypted in PostgreSQL with associated data
`oauth_provider_setting:<setting-id>:client_secret`. The stored secret never
returns to the browser. With an unchanged client ID, a blank secret keeps the
current ciphertext; changing the client ID requires a new secret.

The legacy `MANIFOLD_GMAIL_CLIENT_ID` and `MANIFOLD_GMAIL_CLIENT_SECRET`
variables are ignored, not imported, and never used as fallback. Gmail endpoint
overrides remain static operator/development settings. Gmail is unavailable until
the database setting is saved.

Enable the Gmail API, configure only `openid`, `email`, `gmail.readonly`, and
`gmail.send` on the Google consent screen, and use
`/settings/oauth/gmail/help` to copy the deployed exact callback
`https://<host>/connectors/gmail/callback`. List test identities while the app is
in testing mode and complete Google verification before public use. The Settings
routes use the trusted-local-instance boundary and are not administrator-authenticated.

Changing the client ID or secret, or removing the setting, immediately marks
existing Gmail authorizations and receive/send methods `reconnect_required` and
disables the methods. No restart is required and nothing resumes automatically.
Removal retains encrypted user grants locally and does not revoke Google access.

## Scoped verification

```sh
devenv shell -- mix test \
  apps/manifold_data/test/manifold/migrations/add_oauth_provider_settings_test.exs \
  apps/manifold_connectors/test/manifold/connectors/oauth_provider_catalog_test.exs \
  apps/manifold_connectors/test/manifold/connectors/schema/oauth_provider_setting_test.exs \
  apps/manifold_connectors/test/manifold/connectors/provider_settings_test.exs \
  apps/manifold_connectors/test/manifold/connectors/provider_config_test.exs

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

Use this read-only prerequisite check before `20260818000100`:

```sql
SELECT version
FROM schema_migrations
WHERE version IN (
  20260811000500,
  20260811000600,
  20260811000700,
  20260812000100,
  20260812000200,
  20260812000300
)
ORDER BY version;
```

All six rows must be present.

- [ ] Confirm all old Phoenix, connector, and Oban workers are drained before
      any migration step.
- [ ] Before applying `20260818000100`, query `schema_migrations` and verify that
      `20260811000500`, `20260811000600`, `20260811000700`,
      `20260812000100`, `20260812000200`, and `20260812000300` are already
      applied. Never apply the OAuth provider-settings migration first and then
      attempt to run these older Gmail/Microsoft migrations.
- [ ] Apply `20260818000100` only after the prerequisite versions are present;
      inspect its constraints and confirm it did not import environment values.
- [ ] Save Google credentials at `/settings/oauth` and verify Gmail immediately
      becomes selectable in both receive and send pickers without restart.
- [ ] Verify `/settings/oauth/gmail/help` renders the deployed exact callback and
      the four expected scopes.
- [ ] Inspect migrated shared authorization rows without exposing ciphertext.
- [ ] Confirm Gmail API is enabled, consent scopes are configured, the exact HTTPS
      callback is registered, and the test identity is authorized for staging.
- [ ] Create two distinct Manifold accounts whose exact addresses match two
      distinct Gmail identities. Connect receive for both and verify each account
      imports only its own Gmail mailbox with no cross-account authorization or
      message visibility.
- [ ] Upgrade both accounts with send access, send a distinct plain-text message
      from each, and verify each message appears only in the correct Gmail Sent
      mailbox with the expected sender and reply headers.
- [ ] On one identity also exercise send-first then receive-upgrade and verify the
      account retains one shared authorization with the union of both scopes.
- [ ] Force token expiry in a controlled test account and verify one serialized
      refresh and shared reconnect state.
- [ ] Rotate the secret, change the client ID with a new secret, and remove the
      setting; verify each change requires reconnect, disables affected methods,
      never auto-resumes them, and removal does not revoke Google access.
- [ ] Send through the configured SMTP relay and verify acceptance manually.
- [ ] Simulate ambiguous Gmail and SMTP transport outcomes and verify
      `submission_uncertain` with no automatic second request.
- [ ] Confirm a compose attempt without a method preserves its draft and links to
      Add send method.
- [ ] Confirm legacy Resend lifecycle and webhook records remain readable.
- [ ] Exercise guarded down migrations only on disposable staging data and verify
      their documented refusal conditions, including settings/fenced transaction
      refusal for `20260818000100`.

## Follow-ups

- HTML composition and outbound attachments.
- Gmail and SMTP sender aliases.
- Gmail watch and Microsoft Graph subscription push optimization; polling remains
  the durable fallback.
