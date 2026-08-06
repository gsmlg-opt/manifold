# Account replaces Mailbox as the user-visible local identity

## Decision

Settings exposes **Accounts** only (name + email address). Domains are derived automatically from the address for SMTP routing. Aliases are retired from the product surface. Each account may have multiple **receive methods**, but only one may be enabled at a time.

## Model

- `Manifold.Accounts.Schema.Account` — table still `mailboxes`; `name` maps to `display_name`
- `Manifold.Connectors.Schema.ReceiveMethod` — table still `connector_accounts`; `kind` maps to `provider`, `account_id` maps to `mailbox_id`; new `enabled` boolean with partial unique index (one enabled method per account)
- Implemented kinds: `gmail`, `microsoft`, `imap`
- Placeholder kinds: `pop3`, `eas`, `ews` (`status: not_implemented`, never synced)

## UI

- `/settings/accounts` — list accounts
- `/settings/accounts/new` — create with name + address
- `/settings/accounts/:id` — manage receive methods (add / enable / sync / disconnect)
- Removed: `/domains`, `/aliases`, `/mailboxes` settings pages

## Recipient resolution

`resolve_recipient/1` resolves active accounts (and plus-addressing) only. Alias routes are no longer consulted.
