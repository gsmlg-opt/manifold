alias Manifold.Accounts

owner_email = System.get_env("MANIFOLD_OWNER_EMAIL", "owner@example.test")
owner_password = System.get_env("MANIFOLD_OWNER_PASSWORD", "manifold-dev-password")

case Accounts.create_owner(%{email: owner_email, password: owner_password}) do
  {:ok, _owner} -> IO.puts("Created owner #{owner_email}")
  {:error, _changeset} -> :ok
end

{:ok, domain} =
  case Accounts.create_domain(%{name: "example.test"}) do
    {:ok, domain} -> {:ok, domain}
    {:error, _changeset} -> {:ok, Accounts.get_domain_by_name!("example.test")}
  end

case Accounts.create_mailbox(domain, %{local_part: "inbox", display_name: "Inbox"}) do
  {:ok, _mailbox} -> IO.puts("Created inbox@example.test")
  {:error, _changeset} -> :ok
end
