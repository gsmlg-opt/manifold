alias Manifold.Accounts

{:ok, domain} =
  case Accounts.create_domain(%{name: "example.test"}) do
    {:ok, domain} -> {:ok, domain}
    {:error, _changeset} -> {:ok, Accounts.get_domain_by_name!("example.test")}
  end

case Accounts.create_mailbox(domain, %{local_part: "inbox", display_name: "Inbox"}) do
  {:ok, _mailbox} -> IO.puts("Created inbox@example.test")
  {:error, _changeset} -> :ok
end
