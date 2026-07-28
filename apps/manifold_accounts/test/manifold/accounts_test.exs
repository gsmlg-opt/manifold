defmodule Manifold.AccountsTest do
  use Manifold.DataCase, async: true

  alias Manifold.Accounts
  alias Manifold.Core.Domain

  test "domain normalization" do
    assert {:ok, "example.test"} = Domain.normalize("Example.TEST")
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
