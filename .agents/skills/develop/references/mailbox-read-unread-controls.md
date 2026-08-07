# Mailbox read / unread controls

## Scope

Mail LiveView folder list:

- 3s auto-mark-read for open conversation
- Mark all read (current folder) with modal confirm
- Click / Ctrl⌘ multi-select + bottom bulk toolbar (read / unread / archive / trash)

## Ownership

| Layer | Module |
|-------|--------|
| Domain | `Manifold.Mail.entry_ids_for_threads/3`, `mark_folder_read/2` |
| UI | `ManifoldWeb.MailLive.Index` |
| Hook | `ConversationRow` in `assets/js/conversation_row.js` |
| Spec | `docs/superpowers/specs/2026-08-07-mailbox-read-unread-controls-design.md` |
| Plan | `docs/superpowers/plans/2026-08-07-mailbox-read-unread-controls.md` |

## Behavior notes

- Click replaces selection and opens; Ctrl/⌘+click toggles without navigation.
- Delete in bulk toolbar uses `Mail.trash/2`.
- Auto-mark cancels on leave/switch/manual unread; failures are logged without flash.
- Provider write-back unchanged: IMAP/EAS via `read_changed`; Gmail/Microsoft local-only.

## Follow-ups

- Shift+range select
- Gmail/Microsoft read write-back
- Configurable auto-mark delay
