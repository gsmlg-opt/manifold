defmodule Manifold.ContactsConcurrencyTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  alias Ecto.Adapters.SQL.Sandbox
  alias Manifold.{Accounts, Contacts, Repo}
  alias Manifold.Data.Schema.Contact

  test "a save with stale ownership cannot bypass the new Account purge fence" do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    suffix = System.unique_integer([:positive])
    {:ok, first} = Accounts.create_account(%{address: "first@race-#{suffix}.example.test"})
    {:ok, second} = Accounts.create_account(%{address: "second@race-#{suffix}.example.test"})

    {:ok, contact} =
      Contacts.create_contact(%{
        full_name: "Original",
        account_id: first.id,
        sync_to_icloud: false
      })

    parent = self()
    barrier = make_ref()

    updater =
      Task.async(fn ->
        :ok = Sandbox.checkout(Repo, sandbox: false)

        try do
          receive do
            :start -> Contacts.update_contact(contact.id, %{full_name: "Stale edit"})
          after
            5_000 -> raise "missing start barrier"
          end
        after
          Sandbox.checkin(Repo)
        end
      end)

    handler = {__MODULE__, barrier}
    event = Keyword.fetch!(Repo.config(), :telemetry_prefix) ++ [:query]

    :ok =
      :telemetry.attach(
        handler,
        event,
        fn _, _, metadata, _ ->
          if self() == updater.pid and is_nil(Process.get(barrier)) and
               String.starts_with?(metadata.query, "SELECT") and
               String.contains?(metadata.query, "FROM \"contacts\"") do
            Process.put(barrier, true)
            send(parent, {:snapshot_read, barrier})

            receive do
              {:continue, ^barrier} -> :ok
            after
              5_000 -> raise "missing ownership barrier"
            end
          end
        end,
        nil
      )

    on_exit(fn ->
      :telemetry.detach(handler)
      send(updater.pid, {:continue, barrier})
      if Process.alive?(updater.pid), do: Process.exit(updater.pid, :kill)
      :ok = Sandbox.checkout(Repo, sandbox: false)

      try do
        Repo.delete_all(from(c in Contact, where: c.id == ^contact.id))
        Repo.delete_all(from(a in Accounts.Schema.Account, where: a.id in ^[first.id, second.id]))
        Repo.delete_all(from(d in Accounts.Schema.Domain, where: d.id == ^first.domain_id))
      after
        Sandbox.checkin(Repo)
      end
    end)

    send(updater.pid, :start)
    assert_receive {:snapshot_read, ^barrier}, 5_000
    assert {:ok, _} = Contacts.update_contact(contact.id, %{account_id: second.id})

    Repo.update_all(from(a in Accounts.Schema.Account, where: a.id == ^second.id),
      set: [purge_requested_at: DateTime.utc_now()]
    )

    send(updater.pid, {:continue, barrier})
    assert {:error, :stale} = Task.await(updater)
    assert Contacts.get_contact(contact.id).full_name == "Original"
    assert Contacts.get_contact(contact.id).account_id == second.id
  end
end
