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

  test "duplicate mailboxes report the error on local part" do
    domain = domain_fixture()
    assert {:ok, _mailbox} = Accounts.create_mailbox(domain, %{local_part: "Person"})
    assert {:error, changeset} = Accounts.create_mailbox(domain, %{local_part: "person"})
    assert {"has already been taken", _metadata} = changeset.errors[:local_part]
    refute Keyword.has_key?(changeset.errors, :domain_id)
  end

  test "exact active mailbox lookup" do
    %{domain: domain, mailbox: mailbox} = mailbox_fixture()

    assert {:ok, route} = Accounts.resolve_recipient("Inbox@#{domain.normalized_domain}")
    assert route.canonical_recipient == "inbox@#{domain.normalized_domain}"
    assert route.mailbox_ids == [mailbox.id]
  end

  test "alias to one mailbox" do
    %{domain: domain, mailbox: mailbox} = mailbox_fixture()
    {:ok, alias} = Accounts.create_alias(domain, %{local_part: "support"})
    {:ok, _target} = Accounts.add_alias_target(alias, mailbox)

    assert {:ok, route} = Accounts.resolve_recipient("support@#{domain.normalized_domain}")
    assert route.mailbox_ids == [mailbox.id]
  end

  test "alias to multiple mailboxes" do
    %{domain: domain, mailbox: first} = mailbox_fixture()
    {:ok, second} = Accounts.create_mailbox(domain, %{local_part: "second"})
    {:ok, alias} = Accounts.create_alias(domain, %{local_part: "team"})
    {:ok, _target} = Accounts.add_alias_target(alias, first)
    {:ok, _target} = Accounts.add_alias_target(alias, second)

    assert {:ok, route} = Accounts.resolve_recipient("team@#{domain.normalized_domain}")
    assert Enum.sort(route.mailbox_ids) == Enum.sort([first.id, second.id])
  end

  test "disabled mailbox rejection" do
    domain = domain_fixture()
    {:ok, _mailbox} = Accounts.create_mailbox(domain, %{local_part: "disabled", active: false})

    assert {:error, %{reason: :unknown_recipient, class: :permanent}} =
             Accounts.resolve_recipient("disabled@#{domain.normalized_domain}")
  end

  test "plus-address resolution for mailbox" do
    %{domain: domain, mailbox: mailbox} = mailbox_fixture()

    assert {:ok, route} = Accounts.resolve_recipient("inbox+receipt@#{domain.normalized_domain}")
    assert route.canonical_recipient == "inbox@#{domain.normalized_domain}"
    assert route.plus_tag == "receipt"
    assert route.mailbox_ids == [mailbox.id]
  end

  test "plus-address resolution for alias" do
    %{domain: domain, mailbox: mailbox} = mailbox_fixture()
    {:ok, alias} = Accounts.create_alias(domain, %{local_part: "team"})
    {:ok, _target} = Accounts.add_alias_target(alias, mailbox)

    assert {:ok, route} = Accounts.resolve_recipient("team+sales@#{domain.normalized_domain}")
    assert route.canonical_recipient == "team@#{domain.normalized_domain}"
    assert route.plus_tag == "sales"
    assert route.mailbox_ids == [mailbox.id]
  end

  test "unknown recipient classification" do
    domain = domain_fixture()

    assert {:error, %{reason: :unknown_recipient, class: :permanent}} =
             Accounts.resolve_recipient("missing@#{domain.normalized_domain}")
  end

  test "resolver determinism" do
    %{domain: domain, mailbox: first} = mailbox_fixture()
    {:ok, second} = Accounts.create_mailbox(domain, %{local_part: "second"})
    {:ok, alias} = Accounts.create_alias(domain, %{local_part: "ops"})
    {:ok, _target} = Accounts.add_alias_target(alias, second)
    {:ok, _target} = Accounts.add_alias_target(alias, first)

    results =
      for _ <- 1..3 do
        {:ok, route} = Accounts.resolve_recipient("ops@#{domain.normalized_domain}")
        route.mailbox_ids
      end

    assert [first_result, first_result, first_result] = results
  end

  test "recipient snapshot is deterministic and exposes only active routes" do
    %{domain: domain, mailbox: mailbox} = mailbox_fixture()
    {:ok, disabled} = Accounts.create_mailbox(domain, %{local_part: "disabled", active: false})
    {:ok, alias} = Accounts.create_alias(domain, %{local_part: "team"})
    {:ok, _target} = Accounts.add_alias_target(alias, mailbox)
    {:ok, _disabled_target} = Accounts.add_alias_target(alias, disabled)

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
               route.mailbox_ids == [mailbox.id] and route.plus_addressing_enabled
           end)

    assert Enum.any?(first.routes, fn route ->
             route.canonical_address == "team@#{domain.normalized_domain}" and
               route.mailbox_ids == [mailbox.id] and route.plus_addressing_enabled
           end)

    refute Enum.any?(
             first.routes,
             &(&1.canonical_address == "disabled@#{domain.normalized_domain}")
           )
  end

  test "recipient snapshot revision advances only when active routes change" do
    %{domain: domain} = mailbox_fixture()

    assert {:ok, first} = Accounts.recipient_snapshot()
    assert {:ok, unchanged} = Accounts.recipient_snapshot()
    assert first.revision == unchanged.revision

    {:ok, _mailbox} = Accounts.create_mailbox(domain, %{local_part: "new-route"})

    assert {:ok, changed} = Accounts.recipient_snapshot()
    assert changed.revision == first.revision + 1
    refute changed.digest == first.digest
  end

  test "ensure_mailbox_for_address creates domain and mailbox" do
    assert {:ok, mailbox} = Accounts.ensure_mailbox_for_address("Person@Example.COM")
    assert mailbox.local_part == "Person"
    assert mailbox.domain.normalized_domain == "example.com"
    assert mailbox.active
  end

  test "ensure_mailbox_for_address reuses existing mailbox" do
    assert {:ok, first} = Accounts.ensure_mailbox_for_address("inbox@reuse.example")
    assert {:ok, second} = Accounts.ensure_mailbox_for_address("inbox@reuse.example")
    assert first.id == second.id
  end

  test "ensure_mailbox_for_address rejects invalid address" do
    assert {:error, %Manifold.Core.Error{}} = Accounts.ensure_mailbox_for_address("not-an-email")
  end

  defp mailbox_fixture do
    domain = domain_fixture()

    {:ok, mailbox} =
      Accounts.create_mailbox(domain, %{local_part: "inbox", display_name: "Inbox"})

    %{domain: domain, mailbox: mailbox}
  end

  defp domain_fixture do
    suffix = System.unique_integer([:positive])
    {:ok, domain} = Accounts.create_domain(%{name: "Example#{suffix}.test"})
    domain
  end
end
