# Mail Sync Button Oban UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When Mail Sync is clicked, keep the existing Oban `SyncAccount` enqueue, disable the Sync button, and rotate the sync icon for the whole incomplete Oban job lifetime, updating via PubSub from Oban job telemetry plus a mount-time query.

**Architecture:** Expose `Connectors.sync_job_running?/1` from the incomplete-job query already used by `ensure_sync_job/2`. Add `ManifoldWeb.SyncNotifier` GenServer that attaches to `[:oban, :job, :start|:stop|:exception]`, filters `Manifold.Connectors.Jobs.SyncAccount`, re-checks `sync_job_running?/1`, and broadcasts on `connector_sync:<external_account_id>`. Mail LiveView assigns `:syncing`, subscribes per receive method, and styles the button/icon accordingly.

**Tech Stack:** Elixir, Oban 2.23 telemetry, Phoenix LiveView + PubSub (`Manifold.PubSub`), ExUnit, CSS keyframes in `app.css`.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-08-07-mail-sync-button-oban-ui-design.md`
- Truth source: Oban incomplete states only (`available`, `scheduled`, `executing`, `retryable`, `suspended`) — not receive-method `status`
- On successful enqueue, LiveView sets `syncing` true immediately (covers queue wait before Oban `:start`)
- Account LiveView Sync button is out of scope
- No real IMAP/EAS E2E in this change
- Run tests via `devenv shell -- mix test …` unless already inside devenv
- Prefer TDD: failing test → implement → pass → commit per task
- After feature lands, update `.agents/skills/develop/references/mail-sync-button-oban-ui.md`

---

## File Map

| Path | Responsibility |
| --- | --- |
| Modify: `apps/manifold_connectors/lib/manifold/connectors.ex` | Public `sync_job_running?/1`; refactor `ensure_sync_job/2` to share incomplete-job query |
| Modify: `apps/manifold_connectors/test/manifold/connectors_test.exs` | Tests for `sync_job_running?/1` |
| Create: `apps/manifold_web/lib/manifold_web/sync_notifier.ex` | Oban telemetry → PubSub sync job status |
| Create: `apps/manifold_web/test/manifold_web/sync_notifier_test.exs` | Notifier broadcast / filter / retry-aware tests |
| Modify: `apps/manifold_web/lib/manifold_web/application.ex` | Start `ManifoldWeb.SyncNotifier` |
| Modify: `apps/manifold_web/lib/manifold_web/live/mail_live/index.ex` | `syncing` assign, subscribe, sync event + handle_info, button attrs |
| Modify: `apps/manifold_web/assets/css/app.css` | Rotate animation for syncing icon |
| Modify: `apps/manifold_web/test/manifold_web/mail_live_test.exs` | LiveView syncing UI / PubSub / mount tests |
| Create: `.agents/skills/develop/references/mail-sync-button-oban-ui.md` | Feature skill note (final task) |

---

### Task 1: `Connectors.sync_job_running?/1`

**Files:**
- Modify: `apps/manifold_connectors/lib/manifold/connectors.ex` (near `enqueue_sync/1` / `ensure_sync_job/2`)
- Test: `apps/manifold_connectors/test/manifold/connectors_test.exs`

**Interfaces:**
- Consumes: `Oban.Job`, `Manifold.Connectors.Jobs.SyncAccount`, existing incomplete-state list in `ensure_sync_job/2`
- Produces:
  - `Manifold.Connectors.sync_job_running?(external_account_id :: Ecto.UUID.t()) :: boolean()`
  - Shared private helper used by both `sync_job_running?/1` and `ensure_sync_job/2` (e.g. `incomplete_sync_job/2`)

- [ ] **Step 1: Write the failing tests**

Add to `Manifold.ConnectorsTest` (same setup that creates a mailbox + Gmail/IMAP account as other enqueue tests):

```elixir
test "sync_job_running? reflects incomplete SyncAccount jobs", %{mailbox: mailbox} do
  assert {:ok, account} =
           Connectors.complete_authorization("gmail", "valid-code", consumed(mailbox.id))

  refute Connectors.sync_job_running?(account.id)

  assert {:ok, _job} = Connectors.enqueue_sync(account.id)
  assert Connectors.sync_job_running?(account.id)

  {count, _} =
    Oban.Job
    |> where([job], job.worker == ^inspect(Manifold.Connectors.Jobs.SyncAccount))
    |> where(
      [job],
      fragment("?->>'external_account_id' = ?", job.args, ^account.id)
    )
    |> Repo.update_all(set: [state: "completed"])

  assert count >= 1
  refute Connectors.sync_job_running?(account.id)
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `devenv shell -- mix test apps/manifold_connectors/test/manifold/connectors_test.exs --only line:<line_of_new_test>`  
(or run the whole file and confirm the new test fails with `UndefinedFunctionError` / no `sync_job_running?/1`)

Expected: FAIL — `sync_job_running?/1` undefined

- [ ] **Step 3: Implement**

In `connectors.ex`, add public API and refactor:

```elixir
@spec sync_job_running?(Ecto.UUID.t()) :: boolean()
def sync_job_running?(account_id) when is_binary(account_id) do
  match?(%Oban.Job{}, incomplete_sync_job(Repo, account_id))
end

defp ensure_sync_job(repo, account_id) do
  incomplete_sync_job(repo, account_id) ||
    account_id
    |> then(&SyncAccount.new(%{"external_account_id" => &1}))
    |> repo.insert!()
end

defp incomplete_sync_job(repo, account_id) do
  Oban.Job
  |> where([job], job.worker == ^inspect(SyncAccount))
  |> where([job], job.state in ~w(available scheduled executing retryable suspended))
  |> where(
    [job],
    fragment("?->>'external_account_id' = ?", job.args, ^account_id)
  )
  |> order_by([job], asc: job.id)
  |> limit(1)
  |> repo.one()
end
```

Replace the previous inline body of `ensure_sync_job/2` with the above (do not duplicate the query).

- [ ] **Step 4: Run tests to verify they pass**

Run: `devenv shell -- mix test apps/manifold_connectors/test/manifold/connectors_test.exs`

Expected: PASS (including existing enqueue uniqueness tests)

- [ ] **Step 5: Commit**

```bash
git add apps/manifold_connectors/lib/manifold/connectors.ex \
  apps/manifold_connectors/test/manifold/connectors_test.exs
git commit -m "$(cat <<'EOF'
feat(connectors): expose sync_job_running? for Oban sync UI

EOF
)"
```

---

### Task 2: `ManifoldWeb.SyncNotifier`

**Files:**
- Create: `apps/manifold_web/lib/manifold_web/sync_notifier.ex`
- Create: `apps/manifold_web/test/manifold_web/sync_notifier_test.exs`
- Modify: `apps/manifold_web/lib/manifold_web/application.ex`

**Interfaces:**
- Consumes: `Connectors.sync_job_running?/1`, Oban telemetry meta `%{job: %Oban.Job{worker: worker, args: args}}`
- Produces:
  - `ManifoldWeb.SyncNotifier.topic(account_id) :: String.t()` → `"connector_sync:" <> account_id`
  - Broadcast: `{:sync_job_changed, account_id, running? :: boolean()}` on `Manifold.PubSub`
  - Child in `ManifoldWeb.Application` children list (before Endpoint)

Oban worker string in jobs/telemetry is `"Manifold.Connectors.Jobs.SyncAccount"` (same as `inspect(SyncAccount)`).

- [ ] **Step 1: Write the failing notifier tests**

```elixir
defmodule ManifoldWeb.SyncNotifierTest do
  use ManifoldWeb.ConnCase, async: false

  alias Manifold.Accounts
  alias Manifold.Connectors
  alias Manifold.Connectors.Jobs.SyncAccount
  alias Manifold.Repo
  alias ManifoldWeb.SyncNotifier

  setup do
    # Same encryption_key / imap fake setup as mail_live_test if needed for create_imap_account
    old_key = Application.get_env(:manifold_connectors, :encryption_key)

    Application.put_env(
      :manifold_connectors,
      :encryption_key,
      Base.encode64(:crypto.strong_rand_bytes(32))
    )

    on_exit(fn ->
      if old_key,
        do: Application.put_env(:manifold_connectors, :encryption_key, old_key),
        else: Application.delete_env(:manifold_connectors, :encryption_key)
    end)

    :ok
  end

  test "broadcasts running true on SyncAccount start and false when no incomplete job" do
    account_id = create_receive_method_id()
    topic = SyncNotifier.topic(account_id)
    Phoenix.PubSub.subscribe(Manifold.PubSub, topic)

    job = %Oban.Job{
      worker: inspect(SyncAccount),
      args: %{"external_account_id" => account_id}
    }

    :ok = SyncNotifier.handle_event([:oban, :job, :start], %{}, %{job: job}, nil)
    assert_receive {:sync_job_changed, ^account_id, true}

    # No incomplete row → stop should report false
    :ok = SyncNotifier.handle_event([:oban, :job, :stop], %{}, %{job: job}, nil)
    assert_receive {:sync_job_changed, ^account_id, false}
  end

  test "ignores non-SyncAccount workers" do
    account_id = Ecto.UUID.generate()
    Phoenix.PubSub.subscribe(Manifold.PubSub, SyncNotifier.topic(account_id))

    job = %Oban.Job{
      worker: "Manifold.Connectors.Jobs.PollAccounts",
      args: %{"external_account_id" => account_id}
    }

    :ok = SyncNotifier.handle_event([:oban, :job, :start], %{}, %{job: job}, nil)
    refute_receive {:sync_job_changed, _, _}, 50
  end

  test "exception keeps running true when an incomplete sync job remains" do
    account_id = create_receive_method_id()
    assert {:ok, _} = Connectors.enqueue_sync(account_id)

    Phoenix.PubSub.subscribe(Manifold.PubSub, SyncNotifier.topic(account_id))

    job = %Oban.Job{
      worker: inspect(SyncAccount),
      args: %{"external_account_id" => account_id}
    }

    :ok = SyncNotifier.handle_event([:oban, :job, :exception], %{}, %{job: job}, nil)
    assert_receive {:sync_job_changed, ^account_id, true}
  end

  defp create_receive_method_id do
    suffix = System.unique_integer([:positive])
    {:ok, domain} = Accounts.create_domain(%{name: "syncnote#{suffix}.test"})
    {:ok, mailbox} = Accounts.create_account(domain, %{local_part: "inbox"})

    assert {:ok, method} =
             Connectors.create_imap_account(%{
               account_id: mailbox.id,
               email_address: "inbox@#{domain.normalized_domain}",
               host: "imap.example.test",
               port: 993,
               tls_mode: "ssl",
               username: "inbox@#{domain.normalized_domain}",
               password: "secret"
             })

    method.id
  end
end
```

Adapt `create_imap_account` attrs to match whatever the current connectors API requires (copy from `mail_live_test.exs`). Ensure `ManifoldWeb.Application` already starts SyncNotifier before these tests run, **or** call `SyncNotifier.handle_event/4` directly (preferred — does not require GenServer attach for unit tests).

- [ ] **Step 2: Run tests to verify they fail**

Run: `devenv shell -- mix test apps/manifold_web/test/manifold_web/sync_notifier_test.exs`

Expected: FAIL — module `ManifoldWeb.SyncNotifier` undefined

- [ ] **Step 3: Implement SyncNotifier + start it**

Create `apps/manifold_web/lib/manifold_web/sync_notifier.ex`:

```elixir
defmodule ManifoldWeb.SyncNotifier do
  @moduledoc false

  use GenServer

  alias Manifold.Connectors
  alias Manifold.Connectors.Jobs.SyncAccount

  @handler_id "manifold-web-sync-notifier"
  @events [
    [:oban, :job, :start],
    [:oban, :job, :stop],
    [:oban, :job, :exception]
  ]
  @sync_worker inspect(SyncAccount)

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec topic(Ecto.UUID.t()) :: String.t()
  def topic(account_id) when is_binary(account_id), do: "connector_sync:" <> account_id

  @impl true
  def init(_opts) do
    :telemetry.detach(@handler_id)
    :ok = :telemetry.attach_many(@handler_id, @events, &__MODULE__.handle_event/4, nil)
    {:ok, nil}
  end

  @impl true
  def terminate(_reason, _state), do: :telemetry.detach(@handler_id)

  @doc false
  def handle_event([:oban, :job, event], _measurements, %{job: %Oban.Job{} = job}, _config)
      when event in [:start, :stop, :exception] do
    with @sync_worker <- job.worker,
         account_id when is_binary(account_id) <- job.args["external_account_id"] do
      running? =
        case event do
          :start -> true
          _ -> Connectors.sync_job_running?(account_id)
        end

      Phoenix.PubSub.broadcast(
        Manifold.PubSub,
        topic(account_id),
        {:sync_job_changed, account_id, running?}
      )
    end

    :ok
  end

  def handle_event(_event, _measurements, _metadata, _config), do: :ok
end
```

Note on `:start`: always broadcast `true` (job is executing). On `:stop`/`:exception`, always re-query so retries keep `true`.

In `application.ex`, insert after `MailNotifier`:

```elixir
ManifoldWeb.MailNotifier,
ManifoldWeb.SyncNotifier,
ManifoldWeb.Endpoint
```

- [ ] **Step 4: Run notifier tests**

Run: `devenv shell -- mix test apps/manifold_web/test/manifold_web/sync_notifier_test.exs`

Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add apps/manifold_web/lib/manifold_web/sync_notifier.ex \
  apps/manifold_web/test/manifold_web/sync_notifier_test.exs \
  apps/manifold_web/lib/manifold_web/application.ex
git commit -m "$(cat <<'EOF'
feat(web): broadcast Oban sync job status via SyncNotifier

EOF
)"
```

---

### Task 3: Mail LiveView syncing UI + CSS

**Files:**
- Modify: `apps/manifold_web/lib/manifold_web/live/mail_live/index.ex`
- Modify: `apps/manifold_web/assets/css/app.css`
- Modify: `apps/manifold_web/test/manifold_web/mail_live_test.exs`

**Interfaces:**
- Consumes: `Connectors.enqueue_sync/1`, `Connectors.sync_job_running?/1`, `Connectors.list_receive_methods_for_account/1`, `ManifoldWeb.SyncNotifier.topic/1`
- Produces assigns:
  - `:syncing` — boolean
  - `:sync_receive_method_id` — `nil | Ecto.UUID.t()`
  - `:subscribed_sync_method_id` — for unsubscribe tracking (or reuse one assign)

- [ ] **Step 1: Extend failing LiveView tests**

Update existing sync test and add cases in `mail_live_test.exs`:

```elixir
test "sync queues job, disables button, and rotates icon until sync_job_changed false", %{
  conn: conn
} do
  mailbox = mailbox_fixture()

  assert {:ok, method} =
           Connectors.create_imap_account(%{
             account_id: mailbox.id,
             email_address: "inbox@#{mailbox.domain.normalized_domain}",
             host: "imap.example.test",
             port: 993,
             tls_mode: "ssl",
             username: "inbox@#{mailbox.domain.normalized_domain}",
             password: "secret"
           })

  assert {:ok, folders} = Mail.list_folders(mailbox.id)
  inbox = Enum.find(folders, &(&1.kind == "inbox"))
  assert {:ok, view, _html} = live(conn, ~p"/mail/#{mailbox.id}/folders/#{inbox.id}")

  html =
    view
    |> element("#sync-button")
    |> render_click()

  assert html =~ "Synchronization queued."
  assert html =~ ~s(id="sync-button")
  assert html =~ "disabled"
  assert html =~ "is-syncing"
  assert Enum.any?(Repo.all(Oban.Job), &(&1.args["external_account_id"] == method.id))

  send(view.pid, {:sync_job_changed, method.id, false})
  html = render(view)
  refute html =~ ~s(disabled)
  # button may still have class without is-syncing
  refute html =~ "is-syncing"
end

test "sync button starts disabled when an incomplete sync job already exists", %{conn: conn} do
  mailbox = mailbox_fixture()

  assert {:ok, method} =
           Connectors.create_imap_account(%{
             account_id: mailbox.id,
             email_address: "inbox@#{mailbox.domain.normalized_domain}",
             host: "imap.example.test",
             port: 993,
             tls_mode: "ssl",
             username: "inbox@#{mailbox.domain.normalized_domain}",
             password: "secret"
           })

  assert {:ok, _} = Connectors.enqueue_sync(method.id)

  assert {:ok, folders} = Mail.list_folders(mailbox.id)
  inbox = Enum.find(folders, &(&1.kind == "inbox"))
  assert {:ok, _view, html} = live(conn, ~p"/mail/#{mailbox.id}/folders/#{inbox.id}")

  assert html =~ "is-syncing"
  assert html =~ "disabled"
end
```

Replace/merge with the existing `"sync queues the enabled receive method for the mailbox"` test so there is one coherent sync UI test plus the mount case. Keep enqueue assertion.

For `disabled` HTML assertions: LiveView may render `disabled=""` — prefer `assert has_element?(view, "#sync-button[disabled]")` after click, and `refute has_element?(view, "#sync-button[disabled]")` after message.

- [ ] **Step 2: Run tests to verify they fail**

Run: `devenv shell -- mix test apps/manifold_web/test/manifold_web/mail_live_test.exs`

Expected: FAIL on missing `is-syncing` / disabled behavior

- [ ] **Step 3: Implement LiveView wiring**

In `mount/3`, add:

```elixir
syncing: false,
sync_receive_method_id: nil,
subscribed_sync_method_id: nil
```

Add helpers:

```elixir
defp sync_receive_method(nil), do: nil

defp sync_receive_method(mailbox) do
  mailbox.id
  |> Connectors.list_receive_methods_for_account()
  |> Enum.find(&(&1.enabled and &1.sync_enabled))
end

defp assign_sync_state(socket, mailbox) do
  method = sync_receive_method(mailbox)
  method_id = method && method.id

  socket
  |> subscribe_sync_method(method_id)
  |> assign(
    sync_receive_method_id: method_id,
    syncing: method_id != nil and Connectors.sync_job_running?(method_id)
  )
end

defp subscribe_sync_method(socket, method_id) do
  if connected?(socket) and socket.assigns.subscribed_sync_method_id != method_id do
    if current = socket.assigns.subscribed_sync_method_id do
      Phoenix.PubSub.unsubscribe(Manifold.PubSub, SyncNotifier.topic(current))
    end

    if method_id do
      Phoenix.PubSub.subscribe(Manifold.PubSub, SyncNotifier.topic(method_id))
    end
  end

  assign(socket, :subscribed_sync_method_id, method_id)
end
```

Call `assign_sync_state(socket, mailbox)` from `handle_params` whenever mailbox is resolved (alongside `subscribe_mailbox`).

Update sync event:

```elixir
def handle_event("sync", _params, %{assigns: %{mailbox: mailbox}} = socket)
    when not is_nil(mailbox) do
  method = sync_receive_method(mailbox)

  case method && Connectors.enqueue_sync(method.id) do
    {:ok, _job} ->
      {:noreply,
       socket
       |> assign(sync_receive_method_id: method.id, syncing: true)
       |> put_flash(:info, "Synchronization queued.")}

    nil ->
      {:noreply,
       put_flash(socket, :error, "No enabled receive method is available to synchronize.")}

    {:error, _reason} ->
      {:noreply, put_flash(socket, :error, "Synchronization could not be queued.")}
  end
end
```

Add:

```elixir
def handle_info({:sync_job_changed, account_id, running?}, socket) do
  if socket.assigns.sync_receive_method_id == account_id do
    {:noreply, assign(socket, :syncing, running?)}
  else
    {:noreply, socket}
  end
end
```

Ensure existing `handle_info` for mailbox changes still works (add clause above/below without swallowing).

Update button markup:

```heex
<button
  id="sync-button"
  type="button"
  class={["sync-button", @syncing && "is-syncing"]}
  phx-click="sync"
  disabled={@syncing}
  title="Sync mail now"
>
  <.dm_mdi name="sync" class="mail-icon" />
  <span>Sync</span>
</button>
```

Alias `ManifoldWeb.SyncNotifier` at the top of the LiveView module.

- [ ] **Step 4: Add CSS**

In `apps/manifold_web/assets/css/app.css`, near `.compose-actions .sync-button`:

```css
.compose-actions .sync-button:disabled {
  cursor: not-allowed;
  opacity: 0.72;
}

.compose-actions .sync-button.is-syncing .mail-icon {
  animation: manifold-sync-rotate 0.9s linear infinite;
}

@media (prefers-reduced-motion: reduce) {
  .compose-actions .sync-button.is-syncing .mail-icon {
    animation: none;
  }
}

@keyframes manifold-sync-rotate {
  from {
    transform: rotate(0deg);
  }
  to {
    transform: rotate(360deg);
  }
}
```

- [ ] **Step 5: Run LiveView tests**

Run: `devenv shell -- mix test apps/manifold_web/test/manifold_web/mail_live_test.exs`

Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add apps/manifold_web/lib/manifold_web/live/mail_live/index.ex \
  apps/manifold_web/assets/css/app.css \
  apps/manifold_web/test/manifold_web/mail_live_test.exs
git commit -m "$(cat <<'EOF'
feat(web): disable sync button and rotate icon while Oban sync runs

EOF
)"
```

---

### Task 4: Skill reference + scoped verification

**Files:**
- Create: `.agents/skills/develop/references/mail-sync-button-oban-ui.md`

**Interfaces:**
- Documents ownership: Connectors query, SyncNotifier, MailLive UI

- [ ] **Step 1: Write skill reference**

```markdown
# Mail Sync Button Oban UI

## Behavior

Mail sidebar Sync enqueues `Connectors.enqueue_sync/1`. While an incomplete
`Manifold.Connectors.Jobs.SyncAccount` Oban job exists for the mailbox receive
method, the button is disabled and the sync icon rotates.

## Ownership

- `Manifold.Connectors.sync_job_running?/1` — incomplete Oban job query
- `ManifoldWeb.SyncNotifier` — Oban job telemetry → PubSub `connector_sync:<id>`
- `ManifoldWeb.MailLive.Index` — `syncing` assign, subscribe, button UI
- Spec: `docs/superpowers/specs/2026-08-07-mail-sync-button-oban-ui-design.md`

## Notes

- Account LiveView Sync button is not wired to this UI yet
- Mount/params always re-query Oban; PubSub covers live updates including cron starts
```

- [ ] **Step 2: Run scoped verification**

```bash
devenv shell -- mix test \
  apps/manifold_connectors/test/manifold/connectors_test.exs \
  apps/manifold_web/test/manifold_web/sync_notifier_test.exs \
  apps/manifold_web/test/manifold_web/mail_live_test.exs
devenv shell -- mix format apps/manifold_connectors/lib/manifold/connectors.ex \
  apps/manifold_web/lib/manifold_web/sync_notifier.ex \
  apps/manifold_web/lib/manifold_web/application.ex \
  apps/manifold_web/lib/manifold_web/live/mail_live/index.ex \
  apps/manifold_web/test/manifold_web/sync_notifier_test.exs \
  apps/manifold_web/test/manifold_web/mail_live_test.exs
```

Expected: all listed tests PASS; format clean

- [ ] **Step 3: Commit**

```bash
git add .agents/skills/develop/references/mail-sync-button-oban-ui.md
git commit -m "$(cat <<'EOF'
docs: record mail sync button Oban UI skill notes

EOF
)"
```

---

## Spec coverage self-check

| Spec requirement | Task |
| --- | --- |
| Enqueue existing Oban SyncAccount | Task 3 (existing enqueue kept) |
| Disable + rotate while incomplete Oban job | Task 3 |
| PubSub via Oban telemetry notifier | Task 2 |
| Mount-time `sync_job_running?` | Task 1 + Task 3 |
| Immediate `syncing` true on enqueue | Task 3 |
| Retry keeps running via re-query | Task 2 |
| Account page out of scope | Global Constraints |
| Skill reference update | Task 4 |

## Placeholder / consistency self-check

- Function name: `sync_job_running?/1` throughout
- Topic: `connector_sync:<id>` via `SyncNotifier.topic/1`
- Message: `{:sync_job_changed, account_id, running?}`
- Worker filter: `inspect(SyncAccount)` / `"Manifold.Connectors.Jobs.SyncAccount"`
- CSS class: `is-syncing`
