defmodule ManifoldWeb.SyncNotifierTest do
  use ManifoldWeb.ConnCase, async: false

  import Ecto.Query

  alias Manifold.Accounts
  alias Manifold.Connectors
  alias Manifold.Connectors.Jobs.SyncAccount
  alias Manifold.Repo
  alias ManifoldWeb.SyncNotifier

  setup do
    old_key = Application.get_env(:manifold_connectors, :encryption_key)
    old_transport = Application.get_env(:manifold_connectors, :imap_transport)
    old_fake = Application.get_env(:manifold_connectors, :imap_fake)

    Application.put_env(
      :manifold_connectors,
      :encryption_key,
      Base.encode64(:crypto.strong_rand_bytes(32))
    )

    Application.put_env(:manifold_connectors, :imap_transport, Manifold.Connectors.IMAP.Fake)

    Application.put_env(:manifold_connectors, :imap_fake, %{
      password_expected: "secret",
      messages: [],
      uidvalidity: 1
    })

    on_exit(fn ->
      restore_env(:encryption_key, old_key)
      restore_env(:imap_transport, old_transport)
      restore_env(:imap_fake, old_fake)
    end)

    :ok
  end

  defp restore_env(key, nil), do: Application.delete_env(:manifold_connectors, key)
  defp restore_env(key, value), do: Application.put_env(:manifold_connectors, key, value)

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

    # create_imap_account enqueues a sync job; complete it so stop reports false
    {count, _} =
      Oban.Job
      |> where([job], job.worker == ^inspect(SyncAccount))
      |> where(
        [job],
        fragment("?->>'external_account_id' = ?", job.args, ^account_id)
      )
      |> Repo.update_all(set: [state: "completed"])

    assert count >= 1

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
