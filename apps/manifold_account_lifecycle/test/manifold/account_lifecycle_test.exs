defmodule Manifold.AccountLifecycleTest do
  use Manifold.DataCase, async: true
  use Oban.Testing, repo: Manifold.Repo

  alias Manifold.AccountLifecycle
  alias Manifold.AccountLifecycle.Jobs.PurgeAccount
  alias Manifold.AccountLifecycle.Purge
  alias Manifold.AccountLifecycle.Schema.{AccountPurge, PurgeDelivery}
  alias Manifold.Accounts
  alias Manifold.Accounts.Schema.{Account, RouteRevision}
  alias Manifold.Connectors.Schema.{ReceiveMethod, SendMethod}

  test "request deletion rejects a confirmation mismatch without changing state" do
    account = account_fixture("mismatch@example.test")
    receive = receive_method_fixture(account.id)
    send = send_method_fixture(account.id)
    revision = route_revision()

    assert {:error, :confirmation_mismatch} =
             AccountLifecycle.request_deletion(account.id, "wrong@example.test")

    unchanged = Accounts.get_account!(account.id)
    assert unchanged.active
    assert is_nil(unchanged.purge_requested_at)
    assert Repo.get!(ReceiveMethod, receive.id).enabled
    assert Repo.get!(ReceiveMethod, receive.id).sync_enabled
    assert Repo.get!(SendMethod, send.id).enabled
    assert route_revision() == revision
    refute Repo.get_by(AccountPurge, mailbox_id: account.id)
    refute_enqueued(worker: PurgeAccount)
  end

  test "request deletion atomically marks, quiesces, persists, and enqueues" do
    account = account_fixture("delete@example.test")
    receive = receive_method_fixture(account.id)
    send = send_method_fixture(account.id)
    revision = route_revision()

    assert {:ok, %AccountPurge{mailbox_id: mailbox_id, status: "requested"} = purge} =
             AccountLifecycle.request_deletion(account.id, "delete@example.test")

    assert mailbox_id == account.id
    purging = Accounts.get_account!(account.id)
    refute purging.active
    assert %DateTime{} = purging.purge_requested_at
    refute Repo.get!(ReceiveMethod, receive.id).enabled
    refute Repo.get!(ReceiveMethod, receive.id).sync_enabled
    refute Repo.get!(SendMethod, send.id).enabled
    assert route_revision() == revision + 1
    assert_enqueued(worker: PurgeAccount, args: %{"purge_id" => purge.id})
    assert incomplete_purge_job_count(purge.id) == 1
  end

  test "duplicate deletion requests preserve the purge and keep one incomplete job" do
    account = account_fixture("duplicate@example.test")

    assert {:ok, purge} =
             AccountLifecycle.request_deletion(account.id, "duplicate@example.test")

    progress = %{"cursor" => Ecto.UUID.generate(), "object_key" => "must-not-leak"}

    advanced =
      purge
      |> AccountPurge.changeset(%{
        status: "running",
        stage: "connectors",
        progress: progress,
        discovered_deliveries: 7,
        purged_deliveries: 3
      })
      |> Repo.update!()

    assert {:ok, same_purge} =
             AccountLifecycle.request_deletion(account.id, "duplicate@example.test")

    assert same_purge.id == purge.id
    assert same_purge.status == advanced.status
    assert same_purge.stage == advanced.stage
    assert same_purge.progress == progress
    assert same_purge.discovered_deliveries == 7
    assert same_purge.purged_deliveries == 3
    assert incomplete_purge_job_count(purge.id) == 1
  end

  test "request deletion rolls every state change back before job insertion" do
    account = account_fixture("rollback@example.test")
    receive = receive_method_fixture(account.id)
    send = send_method_fixture(account.id)
    revision = route_revision()

    assert {:error, %{reason: :before_job_insert}} =
             AccountLifecycle.request_deletion(
               account.id,
               "rollback@example.test",
               fail_at: :before_job_insert
             )

    unchanged = Accounts.get_account!(account.id)
    assert unchanged.active
    assert is_nil(unchanged.purge_requested_at)
    assert Repo.get!(ReceiveMethod, receive.id).enabled
    assert Repo.get!(ReceiveMethod, receive.id).sync_enabled
    assert Repo.get!(SendMethod, send.id).enabled
    assert route_revision() == revision
    refute Repo.get_by(AccountPurge, mailbox_id: account.id)
    refute_enqueued(worker: PurgeAccount)
  end

  test "disable account only deactivates and quiesces, idempotently" do
    account = account_fixture("disable@example.test")
    receive = receive_method_fixture(account.id)
    send = send_method_fixture(account.id)
    revision = route_revision()

    assert {:ok, disabled} = AccountLifecycle.disable_account(account.id)
    refute disabled.active
    assert is_nil(disabled.purge_requested_at)
    refute Repo.get!(ReceiveMethod, receive.id).enabled
    refute Repo.get!(ReceiveMethod, receive.id).sync_enabled
    refute Repo.get!(SendMethod, send.id).enabled
    assert route_revision() == revision + 1
    refute Repo.get_by(AccountPurge, mailbox_id: account.id)
    refute_enqueued(worker: PurgeAccount)

    assert {:ok, disabled_again} = AccountLifecycle.disable_account(account.id)
    assert disabled_again.id == account.id
    assert route_revision() == revision + 1
    refute Repo.get_by(AccountPurge, mailbox_id: account.id)
    refute_enqueued(worker: PurgeAccount)
  end

  test "retry deletion resets only safe failed state and enqueues a new unique job" do
    account = account_fixture("retry@example.test")
    assert {:ok, purge} = AccountLifecycle.request_deletion(account.id, "retry@example.test")
    discard_purge_jobs(purge.id)

    progress = %{"cursor" => Ecto.UUID.generate(), "object_key" => "private-key"}

    failed =
      purge
      |> AccountPurge.changeset(%{
        status: "failed",
        stage: "outbound",
        progress: progress,
        error_class: "temporary",
        error_code: "provider_unavailable",
        error_message: "provider was unavailable",
        discovered_deliveries: 9,
        purged_deliveries: 4,
        shared_retained_deliveries: 2,
        deleted_objects: 3
      })
      |> Repo.update!()

    work =
      Repo.insert!(%PurgeDelivery{
        purge_id: failed.id,
        inbound_delivery_id: Ecto.UUID.generate(),
        disposition: "pending"
      })

    assert {:ok, retried} = AccountLifecycle.retry_deletion(failed.id)
    assert retried.id == failed.id
    assert retried.status == "requested"
    assert retried.stage == "outbound"
    assert retried.progress == progress
    assert retried.discovered_deliveries == 9
    assert retried.purged_deliveries == 4
    assert retried.shared_retained_deliveries == 2
    assert retried.deleted_objects == 3
    assert is_nil(retried.error_class)
    assert is_nil(retried.error_code)
    assert is_nil(retried.error_message)
    assert Repo.get!(PurgeDelivery, work.id).purge_id == failed.id
    assert incomplete_purge_job_count(failed.id) == 1
  end

  test "retry deletion rejects missing, nonfailed, and no-longer-purging requests" do
    assert {:error, %{class: :permanent, reason: :account_purge_not_found}} =
             AccountLifecycle.retry_deletion(Ecto.UUID.generate())

    account = account_fixture("not-failed@example.test")

    assert {:ok, purge} =
             AccountLifecycle.request_deletion(account.id, "not-failed@example.test")

    assert {:error, %{class: :permanent, reason: :invalid_state_transition}} =
             AccountLifecycle.retry_deletion(purge.id)

    discard_purge_jobs(purge.id)

    failed =
      purge
      |> AccountPurge.changeset(%{status: "failed", error_message: "failed"})
      |> Repo.update!()

    {1, nil} =
      Account
      |> where([candidate], candidate.id == ^account.id)
      |> Repo.update_all(set: [purge_requested_at: nil])

    assert {:error, %{class: :permanent, reason: :account_not_purging}} =
             AccountLifecycle.retry_deletion(failed.id)

    assert Repo.get!(AccountPurge, failed.id).status == "failed"
    assert incomplete_purge_job_count(failed.id) == 0
  end

  test "states by mailbox uses one query and returns only redacted lifecycle state" do
    first_account = account_fixture("state-one@example.test")
    second_account = account_fixture("state-two@example.test")
    absent_account = account_fixture("state-absent@example.test")

    first =
      purge_fixture(first_account.id, %{
        status: "running",
        stage: "objects",
        progress: %{"object_key" => "private/raw/message.eml"},
        error_message: nil
      })

    second =
      purge_fixture(second_account.id, %{
        status: "failed",
        stage: "connectors",
        progress: %{"token" => "private-token"},
        error_class: "temporary",
        error_code: "connector_timeout",
        error_message: "Connector timed out"
      })

    {states, queries} =
      capture_repo_queries(fn ->
        AccountLifecycle.states_by_mailbox([
          first_account.id,
          second_account.id,
          absent_account.id
        ])
      end)

    assert queries |> Enum.reject(&transaction_query?/1) |> length() == 1

    assert states == %{
             first_account.id => %{
               purge_id: first.id,
               status: "running",
               stage: "objects",
               error_message: nil
             },
             second_account.id => %{
               purge_id: second.id,
               status: "failed",
               stage: "connectors",
               error_message: "Connector timed out"
             }
           }

    refute inspect(states) =~ "private/raw/message.eml"
    refute inspect(states) =~ "private-token"
    refute inspect(states) =~ "connector_timeout"

    {empty, empty_queries} =
      capture_repo_queries(fn -> AccountLifecycle.states_by_mailbox([]) end)

    assert empty == %{}
    assert Enum.reject(empty_queries, &transaction_query?/1) == []
  end

  test "purge worker has durable uniqueness and terminal behavior" do
    opts = PurgeAccount.__opts__()

    assert opts[:queue] == :account_purge
    assert opts[:max_attempts] == 20

    assert opts[:unique] == [
             period: :infinity,
             fields: [:worker, :args],
             keys: [:purge_id],
             states: [:available, :scheduled, :executing, :retryable]
           ]

    account = account_fixture("worker@example.test")
    requested = purge_fixture(account.id, %{status: "requested"})

    assert {:snooze, 1} =
             PurgeAccount.perform(%Oban.Job{args: %{"purge_id" => requested.id}})

    completed =
      requested
      |> AccountPurge.changeset(%{status: "completed", stage: "completed"})
      |> Repo.update!()

    assert :ok = Purge.run(completed.id, %Oban.Job{})
    assert {:cancel, :account_purge_not_found} = Purge.run(Ecto.UUID.generate(), %Oban.Job{})
  end

  defp account_fixture(address) do
    {:ok, account} = Accounts.create_account(%{address: address})
    account
  end

  defp receive_method_fixture(mailbox_id) do
    Repo.insert!(
      ReceiveMethod.changeset(%ReceiveMethod{}, %{
        account_id: mailbox_id,
        kind: "gmail",
        provider_account_id: Ecto.UUID.generate(),
        email_address: "receive-#{Ecto.UUID.generate()}@example.test",
        status: "connected",
        enabled: true,
        sync_enabled: true,
        granted_scopes: []
      })
    )
  end

  defp send_method_fixture(mailbox_id) do
    Repo.insert!(
      SendMethod.changeset(%SendMethod{}, %{
        account_id: mailbox_id,
        kind: "smtp",
        email_address: "send-#{Ecto.UUID.generate()}@example.test",
        status: "connected",
        enabled: true
      })
    )
  end

  defp purge_fixture(mailbox_id, attrs) do
    %AccountPurge{}
    |> AccountPurge.changeset(Map.put(attrs, :mailbox_id, mailbox_id))
    |> Repo.insert!()
  end

  defp route_revision do
    Repo.one!(from(revision in RouteRevision, select: revision.revision))
  end

  defp incomplete_purge_job_count(purge_id) do
    PurgeAccount
    |> purge_job_query(purge_id)
    |> where([job], job.state in ~w(available scheduled executing retryable))
    |> Repo.aggregate(:count)
  end

  defp discard_purge_jobs(purge_id) do
    PurgeAccount
    |> purge_job_query(purge_id)
    |> Repo.update_all(set: [state: "discarded"])
  end

  defp purge_job_query(worker, purge_id) do
    from(job in Oban.Job,
      where:
        job.worker == ^inspect(worker) and
          fragment("?->>'purge_id'", job.args) == ^purge_id
    )
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

  defp transaction_query?(query), do: query in ["begin", "commit", "rollback"]
end
