# Gmail shared authorization lifecycle

## Ownership

- `Manifold.Connectors.OAuthAuthorizations` owns shared Gmail and Microsoft
  authorization creation, incremental scope upgrades, serialized refresh,
  disconnects, active-account checkout fences, and reconnect propagation.
- Gmail and Microsoft each share one provider-specific
  `connector_oauth_authorizations` row across receive and send. Scopes and
  provider adapters remain provider-specific; password connectors retain their
  existing credential paths.
- Connector lifecycle events use exactly one legacy receive-method or shared
  authorization anchor.

## Migrations

- `20260811000500_add_shared_gmail_authorizations.exs` is immutable after release
  and owns the shared authorization and method schema.
- `20260811000600_add_oauth_authorization_events.exs` adds authorization-anchored
  connector events so environments with `00100` already recorded upgrade safely.
- Rolling `00200` back maps each authorization event to its sole Gmail receive
  method. Rollback refuses authorization events without exactly one such method.

## Lifecycle invariants

- Reconnect-required authorization errors disable all dependent Gmail methods and
  retain encrypted tokens and permanent subject identity.
- A successful incremental reauthorization repairs every reconnect-required Gmail
  receive and send method attached to the validated scope union. Each direction
  disables only its own currently enabled alternate before resuming.
- Public enable APIs reject reconnect-required receive and send methods with
  `:reauthorization_required` before changing any currently enabled alternate.
- Lifecycle paths use explicit lock orders for their state boundary: callback
  persistence for generation-fenced Gmail callbacks acquires the provider
  advisory lock, revalidates the provider-setting UUID and lock version, then
  serializes on the active mailbox before authorization/method rows;
  token checkout validates and locks the active mailbox before locking the
  authorization; reconnect/disconnect operations lock only the authorization and
  dependent methods and do not acquire the mailbox lock afterward.
- Gmail OAuth starts resolve client credentials from the encrypted provider
  setting and snapshot its UUID and lock version into the one-time transaction.
  Consume rejects and invalidates changed, removed, recreated, or corrupt
  generations. Completion exchanges outside any database transaction, then
  repeats generation validation under the provider lock before writing account,
  authorization, method, event, cursor, or job state. Legacy and Microsoft
  transactions retain nil generation fields.
- Every Gmail runtime operation resolves the current provider setting without a
  cross-operation cache. Code exchange, access-token refresh, authorized method
  setup, receive sync, and send checkout all receive
  `ProviderConfig.Resolved.config`; sync and send carry one resolved config
  through the operation to avoid a second database read. Microsoft continues to
  use its application configuration.
- Missing, corrupt, or unavailable Gmail settings fail before provider I/O with
  normalized, secret-free configuration errors. Legacy application client
  credentials are ignored; only trusted endpoint and test-transport overrides
  are merged into the stored credentials by `ProviderConfig`.
- Sync and outbound stop telemetry preserve the bounded
  `provider_configuration_error` code for corrupt settings without exposing the
  stored secret or encryption details.
- Receive sync snapshots the method after entering `syncing`; configuration or
  token preflight failures may write `failed` only while the locked method still
  matches that binding, enabled state, phase, and lock version. Concurrent
  provider-setting rotation/removal therefore preserves the newer
  `reconnect_required` lifecycle and encrypted OAuth tokens.
- Direct Gmail receive deletion cancels pending sync work and disconnects and
  clears the authorization only when no live receive or send method remains.
- When Google omits `scope` from an authorization-code response, the adapter uses
  the consumed OAuth transaction's required scopes. Connector callers cannot
  replace that fallback through provider options.
- Same-account callback races serialize on the mailbox row. Cross-account reuse of
  one provider subject is rejected by the provider-subject unique constraint.
- Microsoft receive uses `Mail.Read`; Microsoft send independently adds
  `Mail.Send`. Gmail continues to use its provider-specific readonly/send scopes.

## Verification notes

- Exercise both fresh migrations and the real upgrade path with `00100` already in
  `schema_migrations`.
- For `00200`, verify populated down/up event preservation and refusal when an
  authorization-only event has no unique legacy receive anchor.
