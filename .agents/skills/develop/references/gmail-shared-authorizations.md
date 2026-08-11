# Gmail shared authorization lifecycle

## Ownership

- `Manifold.Connectors.GmailAuthorizations` owns Gmail authorization creation,
  incremental scope upgrades, disconnects, and reconnect-required propagation.
- Gmail receive and send methods share `connector_oauth_authorizations`; Microsoft
  and password-based connectors retain their existing credential paths.
- Connector lifecycle events use exactly one legacy receive-method or shared
  authorization anchor.

## Migrations

- `20260811000100_add_shared_gmail_authorizations.exs` is immutable after release
  and owns the shared authorization and method schema.
- `20260811000200_add_oauth_authorization_events.exs` adds authorization-anchored
  connector events so environments with `00100` already recorded upgrade safely.
- Rolling `00200` back maps each authorization event to its sole Gmail receive
  method. Rollback refuses authorization events without exactly one such method.

## Lifecycle invariants

- Reconnect-required authorization errors disable all dependent Gmail methods and
  retain encrypted tokens and permanent subject identity.
- Public enable APIs reject reconnect-required receive and send methods with
  `:reauthorization_required` before changing any currently enabled alternate.
- Same-account callback races serialize on the mailbox row. Cross-account reuse of
  one provider subject is rejected by the provider-subject unique constraint.

## Verification notes

- Exercise both fresh migrations and the real upgrade path with `00100` already in
  `schema_migrations`.
- For `00200`, verify populated down/up event preservation and refusal when an
  authorization-only event has no unique legacy receive anchor.
