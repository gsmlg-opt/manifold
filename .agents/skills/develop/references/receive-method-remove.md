# Receive method add/remove

## Scope

Account settings receive methods: only implemented kinds can be added; methods
can be permanently removed.

## Ownership

| Area | Module |
| --- | --- |
| Delete API | `Manifold.Connectors.delete_receive_method/1` |
| Account show actions | `ManifoldWeb.AccountLive.Show` (`remove` event) |
| Add method kinds | `ManifoldWeb.AccountLive.ReceiveMethodNew` |

## Behavior

1. **Add** — kind picker is `gmail`, `microsoft`, `imap`, `eas` only. POP3/EWS
   placeholders are not offered (still allowed as schema kinds for legacy rows).
2. **Remove** — deletes the `connector_accounts` row (child credentials/cursors/
   remotes/events cascade) and cancels pending `SyncAccount` Oban jobs.
3. Disconnect remains soft (status `disconnected`); remove is hard delete.

## Tests

- `apps/manifold_web/test/manifold_web/account_live_test.exs`
- `apps/manifold_web/test/manifold_web/external_accounts_web_test.exs`
- `apps/manifold_connectors/test/manifold/connectors_test.exs`

## Follow-ups

- Optionally remove `create_placeholder_receive_method/3` once no tests/seeders need it
- Mirror remove action for send methods if product wants parity
