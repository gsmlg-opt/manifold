# Mail list actions (sync / compose / unread filter)

## Scope

Webmail list UX in `ManifoldWeb.MailLive.Index`:

- Sidebar action group `[Sync] | [Compose]`
- Folder header total message count
- Unread quick filter (`?unread=1`)

## Ownership

| Layer | Module / path |
|-------|----------------|
| UI | `apps/manifold_web/lib/manifold_web/live/mail_live/index.ex` |
| Styles | `apps/manifold_web/assets/css/app.css` (`.compose-actions`, `.folder-total-count`, `.unread-filter`) |
| Query | `Manifold.Mail.Mailbox.list_conversations/3` (`unread_only:` opt) |
| Sync | `Manifold.Connectors.enqueue_sync/1` via enabled receive method for mailbox |

## Behavior

1. **Sync** — finds the mailbox’s enabled + `sync_enabled` receive method and enqueues Oban sync; flashes success/error.
2. **Compose** — unchanged draft creation flow.
3. **Total count** — `@folder.total_count` beside the folder title.
4. **Unread filter** — toggle patches `unread=1`; `list_conversations` keeps threads with any unread entry (`BOOL_OR(read_at IS NULL)`).

## Tests

- `apps/manifold_mail/test/manifold/mail/mailbox_test.exs` — `unread_only` filtering
- `apps/manifold_web/test/manifold_web/mail_live_test.exs` — UI count, filter patch, sync enqueue

## Follow-ups

- Optional: sync all enabled receive methods when an account has more than one
- Optional: persist unread filter preference per mailbox
