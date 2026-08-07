# Mailbox Read / Unread Controls Design

**Date:** 2026-08-07  
**Status:** Approved for planning  
**Scope:** Mail LiveView folder list + conversation reader — auto-mark read, mark-all-read, multi-select bulk actions

## Goal

In the mailbox view, users can reliably control read/unread state and apply common bulk actions:

1. Opening a conversation marks its unread entries as read after **3 seconds** (cancellable).
2. **Mark all as read** for the **current folder**, behind a confirmation modal.
3. **Multi-select** conversations (click selects+opens; Ctrl/⌘+click toggles without opening) and bulk **read / unread / archive / delete (trash)** via a bottom floating toolbar.

## Decisions

| Decision | Choice |
| --- | --- |
| Architecture | LiveView selection state + thin domain APIs; reuse `Mail.mark_read/3`, `archive/2`, `trash/2` |
| Selection | Click → replace selection with that thread and open; Ctrl/⌘+click → toggle selection, no navigation |
| Bulk toolbar | Bottom floating bar (Gmail-style) when `selected_thread_ids` is non-empty |
| Mark all read scope | Current folder only |
| Mark all read confirm | Centered modal showing folder name + unread count |
| Delete | Move to Trash (`Mail.trash/2`) |
| Auto-mark target | All unread `mailbox_entries` for the open thread in the current folder |
| Auto-mark timing | 3000ms via `Process.send_after`; cancel on leave/switch/manual unread |
| Provider write-back | Unchanged: IMAP/EAS via existing `read_changed` telemetry; Gmail/Microsoft local-only |
| Clear selection | On folder change and on list pagination (`after` cursor change) |
| Out of scope | Shift+range select; permanent delete; cross-folder move; configurable auto-read delay; Gmail/Microsoft write-back |

## Architecture

```text
Click row
  → select thread (replace) + patch open conversation
  → schedule {:auto_mark_read, thread_id} in 3000ms

Ctrl/⌘+click row
  → toggle thread in selected_thread_ids
  → do not navigate / do not reschedule auto-mark

Auto-mark fires
  → resolve unread entry_ids for thread in folder
  → Mail.mark_read(mailbox_id, entry_ids, true)
  → reload list + folder unread_count

Mark all read (modal confirm)
  → Mail.mark_folder_read(mailbox_id, folder_id)
  → UPDATE entries in folder where read_at IS NULL
  → emit read_changed telemetry for affected ids
  → reload

Bulk toolbar action
  → resolve entry_ids for selected threads in current folder
  → mark_read / archive / trash
  → clear selection on success; close reader if open thread left folder
```

### Components

1. **`Mail.mark_folder_read/2`** (new)  
   - Signature: `mark_folder_read(mailbox_id, folder_id) :: {:ok, non_neg_integer()} | {:error, Error.t()}`  
   - Updates all non-quarantined entries in that folder with `read_at IS NULL`.  
   - Emits `[:manifold, :mail, :mailbox, :read_changed]` with the affected entry ids (same contract as `mark_read/3`) so IMAP/EAS push continues to work.  
   - Exposed via `Manifold.Mail` delegate.

2. **`Mail.entry_ids_for_threads/3`** (new public API)  
   - `entry_ids_for_threads(mailbox_id, folder_id, thread_ids) :: {:ok, [Ecto.UUID.t()]} | {:error, Error.t()}`  
   - Returns non-quarantined entry ids for those threads in the given folder. LiveView must not invent SQL for bulk resolution.

3. **`ManifoldWeb.MailLive.Index`**
   - Assigns: `selected_thread_ids` (`MapSet`), `confirm_mark_all_read?` (boolean), `auto_mark_timer` (ref or nil), `auto_mark_thread_id`.
   - Conversation rows: stop using bare `<.link navigate>` for primary click. Use `phx-click` with a JS hook (or `phx-click` + `metaKey`/`ctrlKey` in event payload) so Ctrl/⌘ does not open a new browser tab.
   - Bottom toolbar: visible when selection non-empty; actions Read / Unread / Archive / Delete; show selection count.
   - Folder header: **Mark all read** button → opens modal; Confirm → `mark_folder_read`; Cancel → close.
   - Existing per-message Mark read/unread in the reader remains.

4. **CSS / duskmoon**  
   - Row selected state (distinct from `is-unread` / `is-selected` for open conversation; open+selected may combine).  
   - Bottom floating toolbar using design tokens (no hardcoded chrome hex per `DESIGN.md`).  
   - Modal via existing duskmoon/dialog patterns if present; otherwise a simple LiveView-controlled overlay consistent with mail chrome.

### Auto-mark read detail

| Event | Behavior |
| --- | --- |
| Open conversation (click or direct URL) | Cancel prior timer; if any unread entry in thread+folder, start 3s timer |
| Timer fires for still-open thread | `mark_read(..., true)` for those unread entries; refresh assigns |
| Navigate away / close reader / open different thread | Cancel timer |
| User marks unread before timer | Cancel timer for that thread (avoid immediately re-marking); do not auto-restart until conversation is re-opened |
| Conversation already fully read | Do not schedule timer |

## Error handling & edge cases

| Case | Behavior |
| --- | --- |
| Bulk / mark-all failure | Flash error; keep selection (retry); leave modal open only if confirm failed after click |
| Auto-mark failure | Log; no flash; UI stays unread until a later successful mutation |
| Mark all when `unread_count == 0` | Close/no-op with gentle flash (“Nothing to mark”) |
| Selected threads leave folder after archive/trash | Clear selection; if open conversation was among them, close reader and return to folder list |
| Partial entry updates | APIs return count; UI reloads authoritative list/folders |
| Multi-tab | Each LiveView has its own selection; read state converges on reload / PubSub if already used for mail updates |
| Invalid UUIDs / wrong mailbox | Existing `mutate/2` error path |

## Testing

| Area | Coverage |
| --- | --- |
| `Mail.mark_folder_read/2` | Only current folder unread entries change; other folders untouched; telemetry/read_changed when count > 0 |
| `entry_ids_for_threads` | Returns entries for selected threads in folder only |
| LiveView selection | Click selects+opens; Ctrl/⌘ toggle without path change |
| Bulk toolbar | Read / unread / archive / trash on selected threads |
| Mark all read | Modal → confirm → folder `unread_count` becomes 0 |
| Auto-mark | After open, advance 3s → unread cleared; leave early → still unread |
| Selection reset | Folder change and pagination clear `selected_thread_ids` |

Prefer `devenv shell -- mix test` for targeted apps: `manifold_mail`, `manifold_web`.

## File map (expected)

| Path | Change |
| --- | --- |
| `apps/manifold_mail/lib/manifold/mail.ex` | Delegate `mark_folder_read/2`, `entry_ids_for_threads/3` |
| `apps/manifold_mail/lib/manifold/mail/mailbox.ex` | Implement folder mark-read + thread→entry resolution |
| `apps/manifold_mail/test/manifold/mail/mailbox_test.exs` | Domain tests |
| `apps/manifold_web/lib/manifold_web/live/mail_live/index.ex` | Selection, timer, modal, toolbar, row click |
| `apps/manifold_web/assets/js/*` | Hook for modifier-aware row click if needed |
| `apps/manifold_web/assets/css/app.css` | Selected row + floating toolbar (+ modal if needed) |
| `apps/manifold_web/test/manifold_web/mail_live_test.exs` | UI / LiveView tests |
| `.agents/skills/develop/references/mailbox-read-unread-controls.md` | Feature skill note after implement |

## Success criteria

- Unread filter, folder badges, and list unread styling stay correct after all new actions.
- Opening mail feels like a normal client (auto-read after a short delay) without racing manual unread.
- Power users can multi-select with Ctrl/⌘ and batch triage without leaving the folder view.
- Mark all read cannot be triggered without an explicit modal confirm.
