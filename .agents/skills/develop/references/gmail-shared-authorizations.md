# Gmail shared authorization lifecycle

## Ownership

- `Manifold.Connectors.GmailAuthorizations` owns Gmail authorization creation,
  incremental scope upgrades, disconnects, and reconnect-required propagation.
- Gmail receive and send methods share `connector_oauth_authorizations`; Microsoft
  and password-based connectors retain their existing credential paths.
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
- Gmail lifecycle transactions lock the shared authorization before dependent
  receive or send rows. Disconnect and direct-delete paths discover the
  authorization without a lock, then revalidate provider, authorization, and
  mailbox relations after acquiring authorization-first locks.
- Direct Gmail receive deletion cancels pending sync work and disconnects and
  clears the authorization only when no live receive or send method remains.
- When Google omits `scope` from an authorization-code response, the adapter uses
  the consumed OAuth transaction's required scopes. Connector callers cannot
  replace that fallback through provider options.
- Same-account callback races serialize on the mailbox row. Cross-account reuse of
  one provider subject is rejected by the provider-subject unique constraint.

## Verification notes

- Exercise both fresh migrations and the real upgrade path with `00100` already in
  `schema_migrations`.
- For `00200`, verify populated down/up event preservation and refusal when an
  authorization-only event has no unique legacy receive anchor.
