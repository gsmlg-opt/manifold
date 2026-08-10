defmodule Manifold.AccountsTest do
  use Manifold.DataCase, async: true

  alias Manifold.Accounts
  alias Manifold.Accounts.RecipientSnapshot
  alias Manifold.Accounts.Schema.{Account, RouteRevision}
  alias Manifold.Core.Domain

  test "domain normalization" do
    assert {:ok, "example.test"} = Domain.normalize("Example.TEST")
  end

  test "duplicate domains report the error on name" do
    assert {:ok, _domain} = Accounts.create_domain(%{name: "Duplicate.test"})
    assert {:error, changeset} = Accounts.create_domain(%{name: "duplicate.TEST"})
    assert {"has already been taken", _metadata} = changeset.errors[:name]
    refute Keyword.has_key?(changeset.errors, :normalized_domain)
  end

  test "duplicate accounts report the error on local part" do
    domain = domain_fixture()
    assert {:ok, _account} = Accounts.create_account(domain, %{local_part: "Person"})
    assert {:error, changeset} = Accounts.create_account(domain, %{local_part: "person"})
    assert {"has already been taken", _metadata} = changeset.errors[:local_part]
    refute Keyword.has_key?(changeset.errors, :domain_id)
  end

  test "create_account from name and address derives domain" do
    assert {:ok, account} =
             Accounts.create_account(%{name: "Alice", address: "Alice@Example.COM"})

    assert account.name == "Alice"
    assert account.local_part == "Alice"
    assert account.domain.normalized_domain == "example.com"
    assert Accounts.account_address(account) == "Alice@example.com"
  end

  test "update_account changes name without advancing route revision" do
    assert {:ok, account} =
             Accounts.create_account(%{name: "Alice", address: "alice@example.com"})

    assert {:ok, first} = Accounts.recipient_snapshot()

    assert {:ok, updated} =
             Accounts.update_account(account, %{name: "Alicia", address: "alice@example.com"})

    assert updated.name == "Alicia"
    assert Accounts.account_address(updated) == "alice@example.com"

    assert {:ok, unchanged} = Accounts.recipient_snapshot()
    assert unchanged.revision == first.revision
  end

  test "update_account changes address and advances route revision" do
    assert {:ok, account} =
             Accounts.create_account(%{name: "Alice", address: "alice@example.com"})

    assert {:ok, _domain} = Accounts.create_domain(%{name: "new-domain.example", active: true})
    assert {:ok, first} = Accounts.recipient_snapshot()

    assert {:ok, updated} =
             Accounts.update_account(account, %{
               name: "Alice",
               address: "alice@new-domain.example"
             })

    assert Accounts.account_address(updated) == "alice@new-domain.example"
    assert updated.domain.normalized_domain == "new-domain.example"

    assert {:ok, changed} = Accounts.recipient_snapshot()
    assert changed.revision == first.revision + 1

    assert {:ok, _route} = Accounts.resolve_recipient("alice@new-domain.example")

    assert {:error, %{reason: :unknown_recipient}} =
             Accounts.resolve_recipient("alice@example.com")
  end

  test "update_account rejects duplicate address" do
    assert {:ok, _first} =
             Accounts.create_account(%{name: "One", address: "taken@example.com"})

    assert {:ok, second} =
             Accounts.create_account(%{name: "Two", address: "free@example.com"})

    assert {:error, changeset} =
             Accounts.update_account(second, %{name: "Two", address: "taken@example.com"})

    assert {"has already been taken", _} = changeset.errors[:local_part]
  end

  test "disable_account deactivates once, preserves data, and removes routing eligibility" do
    assert {:ok, account} =
             Accounts.create_account(%{
               name: "Disable Me",
               address: "disable@example.test",
               plus_addressing_enabled: true
             })

    before_revision = route_revision()

    assert {:ok, disabled} = Accounts.disable_account(account.id)
    refute disabled.active
    assert is_nil(disabled.purge_requested_at)
    assert disabled.local_part == account.local_part
    assert disabled.name == account.name
    assert disabled.plus_addressing_enabled == account.plus_addressing_enabled
    assert disabled.domain.id == account.domain.id
    assert route_revision() == before_revision + 1

    refute Enum.any?(Accounts.list_active_accounts(), &(&1.id == account.id))

    assert {:error, %{reason: :mailbox_not_active}} =
             Accounts.active_account_domain_id(account.id)

    assert {:error, %{reason: :sender_not_active}} = Accounts.get_sender_identity(account.id)

    assert {:error, %{reason: :unknown_recipient}} =
             Accounts.resolve_recipient("disable@example.test")

    assert {:error, %{reason: :unknown_recipient}} =
             Accounts.resolve_recipient("disable+tag@example.test")

    assert {:ok, disabled_again} = Accounts.disable_account(account.id)
    refute disabled_again.active
    assert is_nil(disabled_again.purge_requested_at)
    assert route_revision() == before_revision + 1
    assert Accounts.get_account!(account.id).local_part == "disable"
  end

  test "begin_purge verifies the current address and is idempotent" do
    assert {:ok, account} = Accounts.create_account(%{address: "Purge@Example.TEST"})
    now = ~U[2026-08-11 01:02:03.123456Z]
    later = ~U[2026-08-12 01:02:03.123456Z]
    before_revision = route_revision()

    assert {:error, :confirmation_mismatch} =
             Repo.transaction(fn ->
               case Accounts.begin_purge(Repo, account.id, "purge@example.test", now) do
                 {:ok, value} -> value
                 {:error, reason} -> Repo.rollback(reason)
               end
             end)

    unchanged = Accounts.get_account!(account.id)
    assert unchanged.active
    assert is_nil(unchanged.purge_requested_at)
    assert route_revision() == before_revision

    assert {:ok, purging} =
             Repo.transaction(fn ->
               {:ok, purging} =
                 Accounts.begin_purge(Repo, account.id, "  Purge@example.test  ", now)

               purging
             end)

    refute purging.active
    assert purging.purge_requested_at == now
    assert route_revision() == before_revision + 1

    assert {:ok, purging_again} =
             Repo.transaction(fn ->
               {:ok, purging} =
                 Accounts.begin_purge(Repo, account.id, "Purge@example.test", later)

               purging
             end)

    refute purging_again.active
    assert purging_again.purge_requested_at == now
    assert route_revision() == before_revision + 1
  end

  test "a disabled account can begin purge without advancing the route revision again" do
    assert {:ok, account} = Accounts.create_account(%{address: "disabled-purge@example.test"})
    assert {:ok, _disabled} = Accounts.disable_account(account.id)
    after_disable_revision = route_revision()
    now = ~U[2026-08-11 02:03:04.123456Z]

    assert {:ok, purging} =
             Repo.transaction(fn ->
               {:ok, purging} =
                 Accounts.begin_purge(
                   Repo,
                   account.id,
                   "disabled-purge@example.test",
                   now
                 )

               purging
             end)

    refute purging.active
    assert purging.purge_requested_at == now
    assert route_revision() == after_disable_revision
  end

  test "purge markers exclude accounts from every active route even if active is true" do
    assert {:ok, account} = Accounts.create_account(%{address: "defense@example.test"})
    now = ~U[2026-08-11 03:04:05.123456Z]

    {1, nil} =
      Account
      |> where([candidate], candidate.id == ^account.id)
      |> Repo.update_all(set: [active: true, purge_requested_at: now])

    refute Enum.any?(Accounts.list_active_accounts(), &(&1.id == account.id))

    assert {:error, %{reason: :mailbox_not_active}} =
             Accounts.active_account_domain_id(account.id)

    assert {:error, %{reason: :sender_not_active}} = Accounts.get_sender_identity(account.id)

    assert {:error, %{reason: :unknown_recipient}} =
             Accounts.resolve_recipient("defense@example.test")

    assert {:error, %{reason: :unknown_recipient}} =
             Accounts.resolve_recipient("defense+tag@example.test")

    assert {:ok, snapshot} = Accounts.recipient_snapshot()

    refute Enum.any?(
             snapshot.routes,
             &(&1.canonical_address == "defense@example.test")
           )
  end

  test "active_account_for_update returns only active non-purging accounts with domain loaded" do
    assert {:ok, account} = Accounts.create_account(%{address: "locked@example.test"})

    {result, queries} =
      capture_repo_queries(fn ->
        Repo.transaction(fn ->
          {:ok, locked} = Accounts.active_account_for_update(Repo, account.id)
          locked
        end)
      end)

    assert {:ok, locked} = result
    assert_mailbox_only_lock_query(queries)

    assert locked.id == account.id
    assert Ecto.assoc_loaded?(locked.domain)
    assert locked.domain.normalized_domain == "example.test"

    assert {:ok, _disabled} = Accounts.disable_account(account.id)

    assert {:ok, {:error, %{class: :permanent, reason: :mailbox_not_active}}} =
             Repo.transaction(fn -> Accounts.active_account_for_update(Repo, account.id) end)

    assert {:ok, purging} = Accounts.create_account(%{address: "locked-purge@example.test"})

    {1, nil} =
      Account
      |> where([candidate], candidate.id == ^purging.id)
      |> Repo.update_all(set: [active: true, purge_requested_at: DateTime.utc_now()])

    assert {:ok, {:error, %{class: :permanent, reason: :mailbox_not_active}}} =
             Repo.transaction(fn -> Accounts.active_account_for_update(Repo, purging.id) end)

    assert {:ok, {:error, %{class: :permanent, reason: :mailbox_not_active}}} =
             Repo.transaction(fn ->
               Accounts.active_account_for_update(Repo, Ecto.UUID.generate())
             end)
  end

  test "account lifecycle transitions lock only the mailbox row" do
    assert {:ok, account} = Accounts.create_account(%{address: "lifecycle-lock@example.test"})

    {result, queries} = capture_repo_queries(fn -> Accounts.disable_account(account.id) end)

    assert {:ok, disabled} = result
    assert disabled.id == account.id
    assert Ecto.assoc_loaded?(disabled.domain)
    assert_mailbox_only_lock_query(queries)
  end

  test "delete_purging_account refuses non-purging accounts and deletes purging accounts" do
    assert {:ok, account} = Accounts.create_account(%{address: "delete@example.test"})

    assert {:ok, {:error, %{class: :permanent, reason: :account_not_purging}}} =
             Repo.transaction(fn -> Accounts.delete_purging_account(Repo, account.id) end)

    assert Accounts.get_account(account.id)

    assert {:ok, {:error, %{class: :permanent, reason: :account_not_found}}} =
             Repo.transaction(fn ->
               Accounts.delete_purging_account(Repo, Ecto.UUID.generate())
             end)

    now = ~U[2026-08-11 04:05:06.123456Z]

    assert {:ok, _purging} =
             Repo.transaction(fn ->
               {:ok, purging} =
                 Accounts.begin_purge(Repo, account.id, "delete@example.test", now)

               purging
             end)

    revision_before_delete = route_revision()

    assert {:ok, deleted} =
             Repo.transaction(fn ->
               {:ok, deleted} = Accounts.delete_purging_account(Repo, account.id)
               deleted
             end)

    assert deleted.id == account.id
    assert is_nil(Accounts.get_account(account.id))
    assert route_revision() == revision_before_delete
  end

  test "exact active account lookup" do
    %{domain: domain, account: account} = account_fixture()

    assert {:ok, route} = Accounts.resolve_recipient("Inbox@#{domain.normalized_domain}")
    assert route.canonical_recipient == "inbox@#{domain.normalized_domain}"
    assert route.mailbox_ids == [account.id]
  end

  test "aliases are no longer resolved" do
    %{domain: domain} = account_fixture()

    assert {:error, %{reason: :unknown_recipient, class: :permanent}} =
             Accounts.resolve_recipient("support@#{domain.normalized_domain}")
  end

  test "disabled account rejection" do
    domain = domain_fixture()
    {:ok, _account} = Accounts.create_account(domain, %{local_part: "disabled", active: false})

    assert {:error, %{reason: :unknown_recipient, class: :permanent}} =
             Accounts.resolve_recipient("disabled@#{domain.normalized_domain}")
  end

  test "plus-address resolution for account" do
    %{domain: domain, account: account} = account_fixture()

    assert {:ok, route} = Accounts.resolve_recipient("inbox+receipt@#{domain.normalized_domain}")
    assert route.canonical_recipient == "inbox@#{domain.normalized_domain}"
    assert route.plus_tag == "receipt"
    assert route.mailbox_ids == [account.id]
  end

  test "unknown recipient classification" do
    domain = domain_fixture()

    assert {:error, %{reason: :unknown_recipient, class: :permanent}} =
             Accounts.resolve_recipient("missing@#{domain.normalized_domain}")
  end

  test "recipient snapshot is deterministic and exposes only active account routes" do
    %{domain: domain, account: account} = account_fixture()
    {:ok, _disabled} = Accounts.create_account(domain, %{local_part: "disabled", active: false})

    now = ~U[2026-07-29 12:00:00Z]

    assert {:ok, %RecipientSnapshot{} = first} = Accounts.recipient_snapshot(now: now)
    assert {:ok, %RecipientSnapshot{} = second} = Accounts.recipient_snapshot(now: now)

    assert first == second
    assert first.schema_version == 1
    assert first.revision > 0
    assert first.generated_at == now
    assert first.expires_at == ~U[2026-07-30 12:00:00Z]
    assert first.digest =~ ~r/^[0-9a-f]{64}$/

    assert Enum.any?(first.domains, &(&1.name == domain.normalized_domain))

    assert Enum.any?(first.routes, fn route ->
             route.canonical_address == "inbox@#{domain.normalized_domain}" and
               route.mailbox_ids == [account.id] and route.plus_addressing_enabled
           end)

    refute Enum.any?(
             first.routes,
             &(&1.canonical_address == "disabled@#{domain.normalized_domain}")
           )
  end

  test "recipient snapshot revision advances only when active routes change" do
    %{domain: domain} = account_fixture()

    assert {:ok, first} = Accounts.recipient_snapshot()
    assert {:ok, unchanged} = Accounts.recipient_snapshot()
    assert first.revision == unchanged.revision

    {:ok, _account} = Accounts.create_account(domain, %{local_part: "new-route"})

    assert {:ok, changed} = Accounts.recipient_snapshot()
    assert changed.revision == first.revision + 1
    refute changed.digest == first.digest
  end

  test "ensure_account_for_address creates domain and account" do
    assert {:ok, account} = Accounts.ensure_account_for_address("Person@Example.COM")
    assert account.local_part == "Person"
    assert account.domain.normalized_domain == "example.com"
    assert account.active
  end

  test "ensure_account_for_address reuses existing account" do
    assert {:ok, first} = Accounts.ensure_account_for_address("inbox@reuse.example")
    assert {:ok, second} = Accounts.ensure_account_for_address("inbox@reuse.example")
    assert first.id == second.id
  end

  test "ensure_account_for_address rejects invalid address" do
    assert {:error, %Manifold.Core.Error{}} = Accounts.ensure_account_for_address("not-an-email")
  end

  defp account_fixture do
    domain = domain_fixture()

    {:ok, account} =
      Accounts.create_account(domain, %{local_part: "inbox", name: "Inbox"})

    %{domain: domain, account: account}
  end

  defp domain_fixture do
    suffix = System.unique_integer([:positive])
    {:ok, domain} = Accounts.create_domain(%{name: "Example#{suffix}.test"})
    domain
  end

  defp route_revision do
    Repo.one!(from(revision in RouteRevision, select: revision.revision))
  end

  defp capture_repo_queries(fun) do
    event = Keyword.fetch!(Repo.config(), :telemetry_prefix) ++ [:query]
    handler_id = {__MODULE__, self(), make_ref()}

    :ok =
      :telemetry.attach(
        handler_id,
        event,
        fn _event, _measurements, metadata, pid -> send(pid, {:repo_query, metadata.query}) end,
        self()
      )

    try do
      result = fun.()
      {result, collect_repo_queries([])}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp collect_repo_queries(queries) do
    receive do
      {:repo_query, query} -> collect_repo_queries([query | queries])
    after
      0 -> Enum.reverse(queries)
    end
  end

  defp assert_mailbox_only_lock_query(queries) do
    assert [lock_query] = Enum.filter(queries, &String.contains?(&1, "FOR UPDATE"))
    assert lock_query =~ ~r/FROM "mailboxes" AS [a-z]\d/
    refute lock_query =~ "JOIN"
    refute lock_query =~ ~s/"domains"/
  end
end
