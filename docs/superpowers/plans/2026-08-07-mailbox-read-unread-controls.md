# Mailbox Read / Unread Controls Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add auto-mark-read (3s), folder mark-all-read with modal confirm, and Ctrl/⌘ multi-select bulk read/unread/archive/trash with a bottom floating toolbar in Mail LiveView.

**Architecture:** Thin Mail domain APIs (`entry_ids_for_threads/3`, `mark_folder_read/2`) plus LiveView selection/timer/modal. Reuse `Mail.mark_read/3`, `archive/2`, `trash/2`. Conversation rows use a JS hook so Ctrl/⌘+click toggles selection without browser new-tab navigation.

**Tech Stack:** Elixir, Ecto, Phoenix LiveView, LiveView JS hooks, ExUnit, duskmoon CSS tokens in `app.css`.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-08-07-mailbox-read-unread-controls-design.md`
- Delete = Trash (`Mail.trash/2`)
- Mark all read = current folder only + centered modal
- Auto-mark = 3000ms; cancel on leave/switch/manual unread; target all unread entries for open thread in current folder
- Selection: click = replace select + open; Ctrl/⌘+click = toggle, no open
- Clear selection on folder change and pagination (`after` cursor change)
- Provider write-back unchanged (IMAP/EAS via `read_changed`; Gmail/Microsoft local-only)
- Out of scope: Shift+range, permanent delete, cross-folder move, configurable delay, Gmail/Microsoft write-back
- Run tests via `devenv shell -- mix test …` unless already inside devenv
- Prefer TDD: failing test → implement → pass → commit per task
- After feature lands, create `.agents/skills/develop/references/mailbox-read-unread-controls.md`
- UI chrome: phoenix_duskmoon tokens only (`DESIGN.md`) — no hardcoded hex for app chrome

---

## File Map

| Path | Responsibility |
| --- | --- |
| Modify: `apps/manifold_mail/lib/manifold/mail.ex` | Delegate `entry_ids_for_threads/3`, `mark_folder_read/2` |
| Modify: `apps/manifold_mail/lib/manifold/mail/mailbox.ex` | Implement both APIs + `read_changed` for folder mark |
| Modify: `apps/manifold_mail/test/manifold/mail/mailbox_test.exs` | Domain tests |
| Create: `apps/manifold_web/assets/js/conversation_row.js` | Modifier-aware row click hook |
| Modify: `apps/manifold_web/assets/js/app.js` | Register `ConversationRow` hook |
| Modify: `apps/manifold_web/lib/manifold_web/live/mail_live/index.ex` | Selection, bulk bar, modal, auto-mark timer, row click |
| Modify: `apps/manifold_web/assets/css/app.css` | `is-checked`, floating toolbar, mark-all modal |
| Modify: `apps/manifold_web/test/manifold_web/mail_live_test.exs` | LiveView UI tests |
| Create: `.agents/skills/develop/references/mailbox-read-unread-controls.md` | Feature skill note |

---

### Task 1: `Mail.entry_ids_for_threads/3`

**Files:**
- Modify: `apps/manifold_mail/lib/manifold/mail.ex`
- Modify: `apps/manifold_mail/lib/manifold/mail/mailbox.ex` (near `mark_read/3`)
- Test: `apps/manifold_mail/test/manifold/mail/mailbox_test.exs`

**Interfaces:**
- Consumes: `MailboxEntry`, existing `valid_uuids?` helpers in `Mailbox`
- Produces:
  - `Manifold.Mail.entry_ids_for_threads(mailbox_id, folder_id, thread_ids) :: {:ok, [Ecto.UUID.t()]} | {:error, Error.t()}`
  - Empty `thread_ids` → `{:ok, []}`
  - Invalid UUIDs → `{:error, ...}` with permanent not_found (match nearby APIs)

- [ ] **Step 1: Write the failing test**

Add to `Manifold.Mail.MailboxTest`:

```elixir
test "entry_ids_for_threads returns folder-scoped entries for selected threads" do
  mailbox_id = mailbox_fixture()
  assert {:ok, folders} = Mail.list_folders(mailbox_id)
  inbox = Enum.find(folders, &(&1.kind == "inbox"))
  archive = Enum.find(folders, &(&1.kind == "archive"))
  now = DateTime.utc_now()

  a = thread_fixture(mailbox_id, inbox.id, "A", now, 2)
  b = thread_fixture(mailbox_id, inbox.id, "B", DateTime.add(now, -10), 1)
  _c = thread_fixture(mailbox_id, inbox.id, "C", DateTime.add(now, -20), 1)

  archived =
    projected_message_fixture(mailbox_id, archive.id, a.thread.id, "Archived in A", now)

  assert {:ok, ids} =
           Mail.entry_ids_for_threads(mailbox_id, inbox.id, [a.thread.id, b.thread.id])

  assert MapSet.new(ids) ==
           MapSet.new(Enum.map(a.entries ++ b.entries, & &1.id))

  refute archived.entry.id in ids

  assert {:ok, []} = Mail.entry_ids_for_threads(mailbox_id, inbox.id, [])
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `devenv shell -- mix test apps/manifold_mail/test/manifold/mail/mailbox_test.exs --only line:<line>`

Expected: FAIL — `entry_ids_for_threads/3` undefined (or similar).

- [ ] **Step 3: Write minimal implementation**

In `mail.ex` after `mark_read/2` delegate:

```elixir
@spec entry_ids_for_threads(Ecto.UUID.t(), Ecto.UUID.t(), [Ecto.UUID.t()]) ::
        {:ok, [Ecto.UUID.t()]} | {:error, Error.t()}
defdelegate entry_ids_for_threads(mailbox_id, folder_id, thread_ids), to: Mailbox
```

In `mailbox.ex`:

```elixir
@spec entry_ids_for_threads(Ecto.UUID.t(), Ecto.UUID.t(), [Ecto.UUID.t()]) ::
        {:ok, [Ecto.UUID.t()]} | {:error, Error.t()}
def entry_ids_for_threads(mailbox_id, folder_id, thread_ids)
    when is_list(thread_ids) do
  ids = [mailbox_id, folder_id | thread_ids]

  if valid_uuids?(ids) do
    if thread_ids == [] do
      {:ok, []}
    else
      entry_ids =
        from(entry in MailboxEntry,
          where:
            entry.mailbox_id == ^mailbox_id and entry.folder_id == ^folder_id and
              entry.thread_id in ^thread_ids and not entry.quarantined,
          select: entry.id
        )
        |> Repo.all()

      {:ok, entry_ids}
    end
  else
    {:error, error(:permanent, :not_found, "invalid mailbox, folder, or thread id")}
  end
rescue
  DBConnection.ConnectionError -> {:error, database_error(:unavailable)}
end
```

(Adjust error helper / `valid_uuids?` usage to match existing private helpers in the same module.)

- [ ] **Step 4: Run test to verify it passes**

Run: `devenv shell -- mix test apps/manifold_mail/test/manifold/mail/mailbox_test.exs`

Expected: PASS for the new test.

- [ ] **Step 5: Commit**

```bash
git add apps/manifold_mail/lib/manifold/mail.ex \
  apps/manifold_mail/lib/manifold/mail/mailbox.ex \
  apps/manifold_mail/test/manifold/mail/mailbox_test.exs
git commit -m "$(cat <<'EOF'
feat: resolve mailbox entry ids for selected threads

EOF
)"
```

---

### Task 2: `Mail.mark_folder_read/2`

**Files:**
- Modify: `apps/manifold_mail/lib/manifold/mail.ex`
- Modify: `apps/manifold_mail/lib/manifold/mail/mailbox.ex`
- Test: `apps/manifold_mail/test/manifold/mail/mailbox_test.exs`

**Interfaces:**
- Consumes: `MailboxEntry`, `Folders.belongs_to_mailbox?/2` (or equivalent folder ownership check), telemetry event `[:manifold, :mail, :mailbox, :read_changed]`
- Produces:
  - `Manifold.Mail.mark_folder_read(mailbox_id, folder_id) :: {:ok, non_neg_integer()} | {:error, Error.t()}`
  - Marks only non-quarantined entries in that folder with `read_at IS NULL`
  - When count > 0, emit `read_changed` with `%{mailbox_id, entry_ids, read?: true}`
  - Also notify mailbox changed via existing `notify_change/2` path

- [ ] **Step 1: Write the failing test**

```elixir
test "mark_folder_read marks only unread entries in the folder" do
  mailbox_id = mailbox_fixture()
  assert {:ok, folders} = Mail.list_folders(mailbox_id)
  inbox = Enum.find(folders, &(&1.kind == "inbox"))
  archive = Enum.find(folders, &(&1.kind == "archive"))
  now = DateTime.utc_now()

  inbox_unread = thread_fixture(mailbox_id, inbox.id, "Inbox unread", now, 1)
  inbox_read = thread_fixture(mailbox_id, inbox.id, "Inbox read", DateTime.add(now, -10), 1)
  archive_unread = thread_fixture(mailbox_id, archive.id, "Archive unread", now, 1)

  assert {:ok, 1} =
           Mail.mark_read(mailbox_id, Enum.map(inbox_read.entries, & &1.id), true)

  assert {:ok, 1} = Mail.mark_folder_read(mailbox_id, inbox.id)

  assert Repo.get!(MailboxEntry, hd(inbox_unread.entries).id).read_at
  assert Repo.get!(MailboxEntry, hd(inbox_read.entries).id).read_at
  assert is_nil(Repo.get!(MailboxEntry, hd(archive_unread.entries).id).read_at)

  assert {:ok, folders_after} = Mail.list_folders(mailbox_id)
  inbox_after = Enum.find(folders_after, &(&1.id == inbox.id))
  assert inbox_after.unread_count == 0

  assert {:ok, 0} = Mail.mark_folder_read(mailbox_id, inbox.id)
end
```

Optional telemetry assertion (if other tests already attach handlers): attach a temporary handler and assert `entry_ids` includes the previously unread inbox entry.

- [ ] **Step 2: Run test to verify it fails**

Run: `devenv shell -- mix test apps/manifold_mail/test/manifold/mail/mailbox_test.exs`

Expected: FAIL — `mark_folder_read/2` undefined.

- [ ] **Step 3: Write minimal implementation**

Delegate in `mail.ex`. Implement in `mailbox.ex`:

```elixir
@spec mark_folder_read(Ecto.UUID.t(), Ecto.UUID.t()) ::
        {:ok, non_neg_integer()} | {:error, Error.t()}
def mark_folder_read(mailbox_id, folder_id) do
  if valid_uuids?([mailbox_id, folder_id]) and
       Folders.belongs_to_mailbox?(folder_id, mailbox_id) do
    entry_ids =
      from(entry in MailboxEntry,
        where:
          entry.mailbox_id == ^mailbox_id and entry.folder_id == ^folder_id and
            is_nil(entry.read_at) and not entry.quarantined,
        select: entry.id
      )
      |> Repo.all()

    case mark_read(mailbox_id, entry_ids, true) do
      {:ok, _count} -> {:ok, length(entry_ids)}
      error -> error
    end
  else
    {:error, error(:permanent, :not_found, "folder not found in mailbox")}
  end
rescue
  DBConnection.ConnectionError -> {:error, database_error(:unavailable)}
end
```

Reuse `mark_read/3` so telemetry + `notify_change` stay consistent. If `mark_read` with `[]` returns `{:ok, 0}` without telemetry, that satisfies the zero-unread case.

(If `Folders.belongs_to_mailbox?/2` does not exist, use the same ownership check pattern as `move/3`.)

- [ ] **Step 4: Run test to verify it passes**

Run: `devenv shell -- mix test apps/manifold_mail/test/manifold/mail/mailbox_test.exs`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/manifold_mail/lib/manifold/mail.ex \
  apps/manifold_mail/lib/manifold/mail/mailbox.ex \
  apps/manifold_mail/test/manifold/mail/mailbox_test.exs
git commit -m "$(cat <<'EOF'
feat: mark all unread entries in a mailbox folder read

EOF
)"
```

---

### Task 3: `ConversationRow` JS hook

**Files:**
- Create: `apps/manifold_web/assets/js/conversation_row.js`
- Modify: `apps/manifold_web/assets/js/app.js`

**Interfaces:**
- Consumes: LiveView hook API (`this.el`, `this.pushEvent`)
- Produces: Hook name `ConversationRow` registered on `LiveSocket`
  - On click: `preventDefault` + `stopPropagation`
  - `pushEvent("select-conversation", { "thread-id": data-thread-id, "modifier": "true"|"false" })` where modifier is `event.ctrlKey || event.metaKey`

- [ ] **Step 1: Add hook module**

`conversation_row.js`:

```javascript
export const ConversationRow = {
  mounted() {
    this._onClick = (event) => {
      event.preventDefault();
      event.stopPropagation();
      const threadId = this.el.dataset.threadId;
      if (!threadId) return;
      const modifier = event.ctrlKey || event.metaKey ? "true" : "false";
      this.pushEvent("select-conversation", {
        "thread-id": threadId,
        modifier,
      });
    };
    this.el.addEventListener("click", this._onClick);
  },
  destroyed() {
    this.el.removeEventListener("click", this._onClick);
  },
};
```

- [ ] **Step 2: Register in `app.js`**

```javascript
import { ConversationRow } from "./conversation_row.js";
// ...
hooks: { ...DuskmoonHooks, ThemeSwitcher, ConversationRow },
```

- [ ] **Step 3: Sanity check JS**

Run: `devenv shell -- mix duskmoon_bundler.js.check` (or the repo’s usual assets check)

Expected: PASS / no syntax errors.

- [ ] **Step 4: Commit**

```bash
git add apps/manifold_web/assets/js/conversation_row.js \
  apps/manifold_web/assets/js/app.js
git commit -m "$(cat <<'EOF'
feat: add ConversationRow hook for modifier-aware selection

EOF
)"
```

---

### Task 4: LiveView selection + open via `select-conversation`

**Files:**
- Modify: `apps/manifold_web/lib/manifold_web/live/mail_live/index.ex`
- Modify: `apps/manifold_web/assets/css/app.css`
- Test: `apps/manifold_web/test/manifold_web/mail_live_test.exs`

**Interfaces:**
- Consumes: Task 3 hook; `folder_thread_path/4`, `folder_path/3`
- Produces:
  - Assign `selected_thread_ids` (`MapSet.t()`), default `MapSet.new()`
  - Event `select-conversation` with `%{"thread-id" => id, "modifier" => "true"|"false"}`
  - Rows: `button.conversation-row` (or `div[role=button]`) with `id={"conversation-row-#{thread_id}"}`, `phx-hook="ConversationRow"`, `data-thread-id`, classes `is-checked` when in selection, `is-selected` when open
  - Clear selection when `folder.id` or `after_cursor` changes in `handle_params`

- [ ] **Step 1: Write the failing LiveView tests**

```elixir
test "clicking a conversation selects and opens it", %{conn: conn} do
  mailbox = mailbox_fixture()
  assert {:ok, folders} = Mail.list_folders(mailbox.id)
  inbox = Enum.find(folders, &(&1.kind == "inbox"))
  thread = projected_thread(mailbox, inbox.id, "Open me", DateTime.utc_now())

  assert {:ok, view, _html} = live(conn, ~p"/mail/#{mailbox.id}/folders/#{inbox.id}")

  view
  |> element("#conversation-row-#{thread.thread.id}")
  |> render_click(%{"thread-id" => thread.thread.id, "modifier" => "false"})

  # If hook-only click does not reach LV in tests, use:
  # render_click(view, "select-conversation", %{"thread-id" => thread.thread.id, "modifier" => "false"})

  assert_patch(
    view,
    ~p"/mail/#{mailbox.id}/folders/#{inbox.id}/threads/#{thread.thread.id}"
  )

  assert has_element?(view, "#conversation-row-#{thread.thread.id}.is-checked")
  assert has_element?(view, "#conversation-row-#{thread.thread.id}.is-selected")
end

test "modifier select toggles without opening", %{conn: conn} do
  mailbox = mailbox_fixture()
  assert {:ok, folders} = Mail.list_folders(mailbox.id)
  inbox = Enum.find(folders, &(&1.kind == "inbox"))
  a = projected_thread(mailbox, inbox.id, "A", DateTime.utc_now())
  b = projected_thread(mailbox, inbox.id, "B", DateTime.add(DateTime.utc_now(), -10))

  assert {:ok, view, _html} = live(conn, ~p"/mail/#{mailbox.id}/folders/#{inbox.id}")

  render_click(view, "select-conversation", %{
    "thread-id" => a.thread.id,
    "modifier" => "false"
  })

  render_click(view, "select-conversation", %{
    "thread-id" => b.thread.id,
    "modifier" => "true"
  })

  assert has_element?(view, "#conversation-row-#{a.thread.id}.is-checked")
  assert has_element?(view, "#conversation-row-#{b.thread.id}.is-checked")
  assert_patch(
    view,
    ~p"/mail/#{mailbox.id}/folders/#{inbox.id}/threads/#{a.thread.id}"
  )
  refute has_element?(view, ".mail-reader h2", "B")
end

test "changing folder clears selection", %{conn: conn} do
  mailbox = mailbox_fixture()
  assert {:ok, folders} = Mail.list_folders(mailbox.id)
  inbox = Enum.find(folders, &(&1.kind == "inbox"))
  archive = Enum.find(folders, &(&1.kind == "archive"))
  a = projected_thread(mailbox, inbox.id, "Stay", DateTime.utc_now())

  assert {:ok, view, _html} = live(conn, ~p"/mail/#{mailbox.id}/folders/#{inbox.id}")

  render_click(view, "select-conversation", %{
    "thread-id" => a.thread.id,
    "modifier" => "false"
  })

  assert has_element?(view, "#conversation-row-#{a.thread.id}.is-checked")

  {:ok, view, _html} =
    live(conn, ~p"/mail/#{mailbox.id}/folders/#{archive.id}")

  # Fresh navigation has empty selection; if same LV process via patch:
  # use element folder link patch instead and refute is-checked on return.
  refute has_element?(view, ".conversation-row.is-checked")
end
```

Prefer `render_click(view, "select-conversation", …)` for reliability in LiveViewTest; keep row `id` + classes for assertions.

- [ ] **Step 2: Run tests to verify they fail**

Run: `devenv shell -- mix test apps/manifold_web/test/manifold_web/mail_live_test.exs`

Expected: FAIL — unknown event / missing row id.

- [ ] **Step 3: Implement selection in LiveView**

Mount assigns:

```elixir
selected_thread_ids: MapSet.new(),
confirm_mark_all_read?: false,
auto_mark_timer: nil,
auto_mark_thread_id: nil
```

In `handle_params`, after computing next folder/after_cursor, if folder or `after` changed vs previous assigns, `assign(:selected_thread_ids, MapSet.new())`.

Event:

```elixir
def handle_event("select-conversation", %{"thread-id" => thread_id} = params, socket) do
  modifier? = params["modifier"] in [true, "true", "1"]

  if modifier? do
    selected =
      if MapSet.member?(socket.assigns.selected_thread_ids, thread_id) do
        MapSet.delete(socket.assigns.selected_thread_ids, thread_id)
      else
        MapSet.put(socket.assigns.selected_thread_ids, thread_id)
      end

    {:noreply, assign(socket, :selected_thread_ids, selected)}
  else
    path =
      folder_thread_path(socket.assigns.mailbox.id, socket.assigns.folder.id, thread_id,
        q: socket.assigns.query,
        unread: unread_param(socket.assigns.unread_only),
        after: socket.assigns.after_cursor
      )

    {:noreply,
     socket
     |> assign(:selected_thread_ids, MapSet.new([thread_id]))
     |> push_patch(to: path)}
  end
end
```

Replace conversation `<.link navigate=…>` with:

```heex
<button
  :for={item <- @page.items}
  type="button"
  id={"conversation-row-#{item.thread_id}"}
  phx-hook="ConversationRow"
  data-thread-id={item.thread_id}
  class={[
    "conversation-row",
    item.unread && "is-unread",
    MapSet.member?(@selected_thread_ids, item.thread_id) && "is-checked",
    @conversation && item.thread_id == @conversation.thread_id && "is-selected"
  ]}
>
  ...
</button>
```

CSS: style `button.conversation-row` like former links; add `.conversation-row.is-checked` using primary-container mix tokens (distinct from `.is-selected`).

- [ ] **Step 4: Run tests to verify they pass**

Run: `devenv shell -- mix test apps/manifold_web/test/manifold_web/mail_live_test.exs`

Expected: PASS for selection tests; existing sync/unread tests still pass.

- [ ] **Step 5: Commit**

```bash
git add apps/manifold_web/lib/manifold_web/live/mail_live/index.ex \
  apps/manifold_web/assets/css/app.css \
  apps/manifold_web/test/manifold_web/mail_live_test.exs
git commit -m "$(cat <<'EOF'
feat: select mail conversations with click and modifier multi-select

EOF
)"
```

---

### Task 5: Bottom floating bulk toolbar

**Files:**
- Modify: `apps/manifold_web/lib/manifold_web/live/mail_live/index.ex`
- Modify: `apps/manifold_web/assets/css/app.css`
- Test: `apps/manifold_web/test/manifold_web/mail_live_test.exs`

**Interfaces:**
- Consumes: `Mail.entry_ids_for_threads/3`, `Mail.mark_read/3`, `Mail.archive/2`, `Mail.trash/2`
- Produces:
  - Toolbar `#bulk-selection-bar` when `MapSet.size(selected_thread_ids) > 0`
  - Events: `bulk-mark-read`, `bulk-mark-unread`, `bulk-archive`, `bulk-trash`
  - On success: clear selection; if open conversation thread was among archived/trashed, `push_patch` to folder list (no thread)
  - On failure: flash error; keep selection

- [ ] **Step 1: Write the failing test**

```elixir
test "bulk toolbar marks selected conversations read", %{conn: conn} do
  mailbox = mailbox_fixture()
  assert {:ok, folders} = Mail.list_folders(mailbox.id)
  inbox = Enum.find(folders, &(&1.kind == "inbox"))
  a = projected_thread(mailbox, inbox.id, "Bulk A", DateTime.utc_now())
  b = projected_thread(mailbox, inbox.id, "Bulk B", DateTime.add(DateTime.utc_now(), -10))

  assert {:ok, view, _html} = live(conn, ~p"/mail/#{mailbox.id}/folders/#{inbox.id}")

  render_click(view, "select-conversation", %{
    "thread-id" => a.thread.id,
    "modifier" => "false"
  })

  render_click(view, "select-conversation", %{
    "thread-id" => b.thread.id,
    "modifier" => "true"
  })

  assert has_element?(view, "#bulk-selection-bar")

  view
  |> element("#bulk-mark-read")
  |> render_click()

  refute has_element?(view, "#conversation-row-#{a.thread.id}.is-unread")
  refute has_element?(view, "#conversation-row-#{b.thread.id}.is-unread")
  refute has_element?(view, "#bulk-selection-bar")
end

test "bulk trash moves selected conversations and clears open reader", %{conn: conn} do
  mailbox = mailbox_fixture()
  assert {:ok, folders} = Mail.list_folders(mailbox.id)
  inbox = Enum.find(folders, &(&1.kind == "inbox"))
  a = projected_thread(mailbox, inbox.id, "Trash me", DateTime.utc_now())

  assert {:ok, view, _html} = live(conn, ~p"/mail/#{mailbox.id}/folders/#{inbox.id}")

  render_click(view, "select-conversation", %{
    "thread-id" => a.thread.id,
    "modifier" => "false"
  })

  view
  |> element("#bulk-trash")
  |> render_click()

  refute has_element?(view, "#conversation-row-#{a.thread.id}")
  refute has_element?(view, ".mail-reader")
  assert_patch(view, ~p"/mail/#{mailbox.id}/folders/#{inbox.id}")
end
```

Add similar coverage for unread + archive (can be one test with two clicks or two small tests).

- [ ] **Step 2: Run tests to verify they fail**

Expected: FAIL — missing `#bulk-selection-bar`.

- [ ] **Step 3: Implement toolbar + events**

HEEx (inside mail shell, sibling to list/reader):

```heex
<div
  :if={MapSet.size(@selected_thread_ids) > 0}
  id="bulk-selection-bar"
  class="bulk-selection-bar"
  role="toolbar"
  aria-label="Bulk conversation actions"
>
  <span class="bulk-selection-count">{MapSet.size(@selected_thread_ids)} selected</span>
  <button type="button" id="bulk-mark-read" phx-click="bulk-mark-read">Mark read</button>
  <button type="button" id="bulk-mark-unread" phx-click="bulk-mark-unread">Mark unread</button>
  <button type="button" id="bulk-archive" phx-click="bulk-archive">Archive</button>
  <button type="button" id="bulk-trash" phx-click="bulk-trash">Delete</button>
</div>
```

Events + helper:

```elixir
def handle_event("bulk-mark-read", _params, socket),
  do: bulk_entries(socket, &Mail.mark_read(socket.assigns.mailbox.id, &1, true), :stay)

def handle_event("bulk-mark-unread", _params, socket),
  do: bulk_entries(socket, &Mail.mark_read(socket.assigns.mailbox.id, &1, false), :stay)

def handle_event("bulk-archive", _params, socket),
  do: bulk_entries(socket, &Mail.archive(socket.assigns.mailbox.id, &1), :leave_if_open)

def handle_event("bulk-trash", _params, socket),
  do: bulk_entries(socket, &Mail.trash(socket.assigns.mailbox.id, &1), :leave_if_open)

defp bulk_entries(socket, fun, mode) do
  thread_ids = MapSet.to_list(socket.assigns.selected_thread_ids)

  with {:ok, entry_ids} <-
         Mail.entry_ids_for_threads(
           socket.assigns.mailbox.id,
           socket.assigns.folder.id,
           thread_ids
         ),
       {:ok, _count} <- fun.(entry_ids) do
    open_id = socket.assigns.conversation && socket.assigns.conversation.thread_id
    leave? = mode == :leave_if_open and open_id in thread_ids

    socket = assign(socket, :selected_thread_ids, MapSet.new())

    socket =
      if leave? do
        push_patch(socket,
          to:
            folder_path(socket.assigns.mailbox.id, socket.assigns.folder.id,
              q: socket.assigns.query,
              unread: unread_param(socket.assigns.unread_only),
              after: socket.assigns.after_cursor
            )
        )
      else
        reload(socket)
      end

    {:noreply, socket}
  else
    {:error, _} ->
      {:noreply, put_flash(socket, :error, "Mailbox action failed.")}
  end
end
```

CSS: fixed/sticky bottom centered bar using `var(--color-inverse-surface)` / `on-inverse` or surface-container-highest + outline tokens — match duskmoon; do not hardcode `#18181b`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `devenv shell -- mix test apps/manifold_web/test/manifold_web/mail_live_test.exs`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/manifold_web/lib/manifold_web/live/mail_live/index.ex \
  apps/manifold_web/assets/css/app.css \
  apps/manifold_web/test/manifold_web/mail_live_test.exs
git commit -m "$(cat <<'EOF'
feat: add bulk read unread archive trash toolbar for mail

EOF
)"
```

---

### Task 6: Mark all read modal

**Files:**
- Modify: `apps/manifold_web/lib/manifold_web/live/mail_live/index.ex`
- Modify: `apps/manifold_web/assets/css/app.css`
- Test: `apps/manifold_web/test/manifold_web/mail_live_test.exs`

**Interfaces:**
- Consumes: `Mail.mark_folder_read/2`, assign `confirm_mark_all_read?`
- Produces:
  - Button `#mark-all-read` in folder header
  - Modal `#mark-all-read-modal` when `confirm_mark_all_read?`
  - Events: `open-mark-all-read`, `cancel-mark-all-read`, `confirm-mark-all-read`
  - If `folder.unread_count == 0` on open/confirm → flash “Nothing to mark.” and do not call API (or call and flash after `{:ok, 0}`)

- [ ] **Step 1: Write the failing test**

```elixir
test "mark all read requires modal confirm", %{conn: conn} do
  mailbox = mailbox_fixture()
  assert {:ok, folders} = Mail.list_folders(mailbox.id)
  inbox = Enum.find(folders, &(&1.kind == "inbox"))
  projected_thread(mailbox, inbox.id, "Unread all", DateTime.utc_now())

  assert {:ok, view, _html} = live(conn, ~p"/mail/#{mailbox.id}/folders/#{inbox.id}")
  assert has_element?(view, "#mark-all-read")
  refute has_element?(view, "#mark-all-read-modal")

  view |> element("#mark-all-read") |> render_click()
  assert has_element?(view, "#mark-all-read-modal")

  view |> element("#confirm-mark-all-read") |> render_click()

  refute has_element?(view, "#mark-all-read-modal")
  refute has_element?(view, ".conversation-row.is-unread")
  assert has_element?(view, ".folder-count") == false or
           not has_element?(view, "#folder-#{inbox.id} .folder-count")
end
```

(Adjust folder unread badge selector to match existing markup — sidebar uses `.folder-count` when `unread_count > 0`.)

- [ ] **Step 2: Run test to verify it fails**

Expected: FAIL — missing `#mark-all-read`.

- [ ] **Step 3: Implement modal + events**

```elixir
def handle_event("open-mark-all-read", _params, socket) do
  if socket.assigns.folder.unread_count == 0 do
    {:noreply, put_flash(socket, :info, "Nothing to mark.")}
  else
    {:noreply, assign(socket, :confirm_mark_all_read?, true)}
  end
end

def handle_event("cancel-mark-all-read", _params, socket),
  do: {:noreply, assign(socket, :confirm_mark_all_read?, false)}

def handle_event("confirm-mark-all-read", _params, socket) do
  case Mail.mark_folder_read(socket.assigns.mailbox.id, socket.assigns.folder.id) do
    {:ok, 0} ->
      {:noreply,
       socket
       |> assign(:confirm_mark_all_read?, false)
       |> put_flash(:info, "Nothing to mark.")}

    {:ok, _count} ->
      {:noreply,
       socket
       |> assign(:confirm_mark_all_read?, false)
       |> reload()}

    {:error, _} ->
      {:noreply, put_flash(socket, :error, "Mailbox action failed.")}
  end
end
```

Modal copy: “Mark all as read?” / “Mark all unread messages in {folder.name} as read.”

- [ ] **Step 4: Run tests to verify they pass**

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/manifold_web/lib/manifold_web/live/mail_live/index.ex \
  apps/manifold_web/assets/css/app.css \
  apps/manifold_web/test/manifold_web/mail_live_test.exs
git commit -m "$(cat <<'EOF'
feat: confirm before marking a mail folder all read

EOF
)"
```

---

### Task 7: Auto-mark read after 3 seconds

**Files:**
- Modify: `apps/manifold_web/lib/manifold_web/live/mail_live/index.ex`
- Test: `apps/manifold_web/test/manifold_web/mail_live_test.exs`

**Interfaces:**
- Consumes: conversation assigns; `Mail.mark_read/3`; `Mail.entry_ids_for_threads/3` or unread entry ids from conversation messages
- Produces:
  - On open conversation with any `message.read == false`: `Process.send_after(self(), {:auto_mark_read, thread_id}, 3_000)` stored in `auto_mark_timer` / `auto_mark_thread_id`
  - `handle_info({:auto_mark_read, thread_id}, …)` only marks if still the open thread and timer matches
  - Cancel timer on close/switch; on `mark-unread` / `bulk-mark-unread` for open thread cancel and do not restart until re-open
  - Failures: `Logger.warning` / silent — no flash

- [ ] **Step 1: Write the failing tests**

```elixir
test "opening a conversation auto-marks read after timer message", %{conn: conn} do
  mailbox = mailbox_fixture()
  assert {:ok, folders} = Mail.list_folders(mailbox.id)
  inbox = Enum.find(folders, &(&1.kind == "inbox"))
  thread = projected_thread(mailbox, inbox.id, "Auto read", DateTime.utc_now())

  assert {:ok, view, _html} =
           live(
             conn,
             ~p"/mail/#{mailbox.id}/folders/#{inbox.id}/threads/#{thread.thread.id}"
           )

  assert has_element?(view, "#conversation-row-#{thread.thread.id}.is-unread")

  send(view.pid, {:auto_mark_read, thread.thread.id})
  html = render(view)

  refute html =~ ~s(id="conversation-row-#{thread.thread.id}") and
           Floki.find(html, "#conversation-row-#{thread.thread.id}.is-unread") != []

  refute has_element?(view, "#conversation-row-#{thread.thread.id}.is-unread")
  assert Repo.get!(MailboxEntry, thread.entry.id).read_at
end

test "leaving a conversation before auto-mark keeps it unread", %{conn: conn} do
  mailbox = mailbox_fixture()
  assert {:ok, folders} = Mail.list_folders(mailbox.id)
  inbox = Enum.find(folders, &(&1.kind == "inbox"))
  thread = projected_thread(mailbox, inbox.id, "Stay unread", DateTime.utc_now())

  assert {:ok, view, _html} =
           live(
             conn,
             ~p"/mail/#{mailbox.id}/folders/#{inbox.id}/threads/#{thread.thread.id}"
           )

  view
  |> element(".reader-back")
  |> render_click()

  send(view.pid, {:auto_mark_read, thread.thread.id})
  _ = render(view)

  assert is_nil(Repo.get!(MailboxEntry, thread.entry.id).read_at)
end
```

Also cover: schedule uses 3000ms — assert via `:erlang.process_info(view.pid, :messages)` is brittle; instead document that production uses `3_000` constant `@auto_mark_read_ms 3_000` and tests send the message. Optional: expose assign or module attribute and assert `ManifoldWeb.MailLive.Index.auto_mark_read_ms() == 3_000` if you add a tiny public helper for tests.

- [ ] **Step 2: Run tests to verify they fail**

Expected: FAIL — unhandled `handle_info` or still unread after send when implementation missing cancel logic incorrectly… first test fails until implemented.

- [ ] **Step 3: Implement timer**

```elixir
@auto_mark_read_ms 3_000

defp schedule_auto_mark_read(socket) do
  socket = cancel_auto_mark_read(socket)
  conversation = socket.assigns.conversation

  cond do
    is_nil(conversation) ->
      socket

    Enum.any?(conversation.messages, &(not &1.read)) ->
      ref = Process.send_after(self(), {:auto_mark_read, conversation.thread_id}, @auto_mark_read_ms)
      assign(socket, auto_mark_timer: ref, auto_mark_thread_id: conversation.thread_id)

    true ->
      socket
  end
end

defp cancel_auto_mark_read(socket) do
  if ref = socket.assigns[:auto_mark_timer], do: Process.cancel_timer(ref)
  assign(socket, auto_mark_timer: nil, auto_mark_thread_id: nil)
end

def handle_info({:auto_mark_read, thread_id}, socket) do
  open? =
    socket.assigns.conversation &&
      socket.assigns.conversation.thread_id == thread_id &&
      socket.assigns.auto_mark_thread_id == thread_id

  socket = assign(socket, auto_mark_timer: nil, auto_mark_thread_id: nil)

  if open? do
    unread_ids =
      socket.assigns.conversation.messages
      |> Enum.reject(& &1.read)
      |> Enum.map(& &1.entry_id)

    case Mail.mark_read(socket.assigns.mailbox.id, unread_ids, true) do
      {:ok, _} -> {:noreply, reload(socket)}
      {:error, reason} ->
        require Logger
        Logger.warning("auto mark read failed: #{inspect(reason)}")
        {:noreply, socket}
    end
  else
    {:noreply, socket}
  end
end
```

Call `schedule_auto_mark_read/1` at end of successful inbound `handle_params` / reload when conversation present. Call `cancel_auto_mark_read/1` when conversation becomes nil or thread changes, and in `mark-unread` / `bulk-mark-unread` when open thread affected.

Important: after `reload` following auto-mark, do **not** immediately reschedule (conversation now fully read → `schedule` no-ops).

- [ ] **Step 4: Run tests to verify they pass**

Run: `devenv shell -- mix test apps/manifold_web/test/manifold_web/mail_live_test.exs apps/manifold_mail/test/manifold/mail/mailbox_test.exs`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/manifold_web/lib/manifold_web/live/mail_live/index.ex \
  apps/manifold_web/test/manifold_web/mail_live_test.exs
git commit -m "$(cat <<'EOF'
feat: auto-mark open mail conversations read after delay

EOF
)"
```

---

### Task 8: Feature skill reference + format

**Files:**
- Create: `.agents/skills/develop/references/mailbox-read-unread-controls.md`
- Touch any files still unformatted from prior tasks

- [ ] **Step 1: Write skill note**

```markdown
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

## Follow-ups

- Shift+range select
- Gmail/Microsoft read write-back
- Configurable auto-mark delay
```

- [ ] **Step 2: Format + run focused tests**

```bash
devenv shell -- mix format \
  apps/manifold_mail/lib/manifold/mail.ex \
  apps/manifold_mail/lib/manifold/mail/mailbox.ex \
  apps/manifold_web/lib/manifold_web/live/mail_live/index.ex \
  apps/manifold_mail/test/manifold/mail/mailbox_test.exs \
  apps/manifold_web/test/manifold_web/mail_live_test.exs

devenv shell -- mix test \
  apps/manifold_mail/test/manifold/mail/mailbox_test.exs \
  apps/manifold_web/test/manifold_web/mail_live_test.exs
```

Expected: all PASS.

- [ ] **Step 3: Commit**

```bash
git add .agents/skills/develop/references/mailbox-read-unread-controls.md
git commit -m "$(cat <<'EOF'
docs: add mailbox read unread controls skill reference

EOF
)"
```

---

## Spec coverage checklist

| Spec requirement | Task |
| --- | --- |
| Click select+open; Ctrl/⌘ toggle no open | 3, 4 |
| Bottom floating bulk toolbar | 5 |
| Bulk read / unread / archive / delete(trash) | 5 |
| Mark all read current folder + modal | 2, 6 |
| Auto-mark 3s + cancel rules | 7 |
| Clear selection on folder / pagination | 4 |
| `entry_ids_for_threads` public API | 1 |
| `mark_folder_read` + read_changed | 2 |
| IMAP/EAS write-back unchanged | 2 (via `mark_read`) |
| Error handling (flash vs silent auto-mark) | 5, 6, 7 |
| Feature skill reference | 8 |
| Out of scope items omitted | — |

## Self-review notes

- No Shift+range / Gmail write-back tasks (YAGNI per spec).
- LiveViewTest uses `render_click(view, "select-conversation", …)` so tests do not depend on JS hook execution.
- `mark_folder_read` reuses `mark_read/3` for telemetry consistency with `ReadPush.Handler`.
