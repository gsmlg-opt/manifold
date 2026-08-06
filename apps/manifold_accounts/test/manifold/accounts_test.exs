defmodule Manifold.AccountsTest do
  use Manifold.DataCase, async: true

  alias Manifold.Accounts
  alias Manifold.Accounts.RecipientSnapshot
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
end
