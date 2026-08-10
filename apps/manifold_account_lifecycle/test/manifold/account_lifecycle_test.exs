defmodule Manifold.AccountLifecycleTest do
  use Manifold.DataCase, async: false
  use Oban.Testing, repo: Manifold.Repo

  alias Manifold.AccountLifecycle
  alias Manifold.AccountLifecycle.Jobs.PurgeAccount
  alias Manifold.AccountLifecycle.Purge
  alias Manifold.AccountLifecycle.Schema.{AccountPurge, PurgeDelivery}
  alias Manifold.Accounts
  alias Manifold.Accounts.Schema.{Account, RouteRevision}
  alias Manifold.Connectors.Schema.{ReceiveMethod, SendMethod}

  setup context do
    opts = Application.fetch_env!(:manifold_data, Oban)

    opts =
      if context[:oban_testing] == :disabled do
        opts
        |> Keyword.put(:testing, :disabled)
        |> Keyword.put(:queues, [])
        |> Keyword.put(:plugins, [])
        |> Keyword.put(:peer, {Oban.Peers.Isolated, leader?: false})
        |> Keyword.put(:stage_interval, :infinity)
      else
        opts
      end

    start_supervised!({Oban, opts})
    :ok
  end

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

  test "a suspended purge job remains unique across duplicate deletion requests" do
    account = account_fixture("suspended@example.test")

    assert {:ok, purge} =
             AccountLifecycle.request_deletion(account.id, "suspended@example.test")

    {1, nil} =
      PurgeAccount
      |> purge_job_query(purge.id)
      |> Repo.update_all(set: [state: "suspended"])

    assert {:ok, same_purge} =
             AccountLifecycle.request_deletion(account.id, "suspended@example.test")

    assert same_purge.id == purge.id
    assert incomplete_purge_job_count(purge.id) == 1
    assert [%Oban.Job{state: "suspended"}] = purge_jobs(purge.id)
  end

  @tag oban_testing: :disabled
  test "concurrent deletion request and retry use Oban uniqueness to persist one job" do
    {:ok, race_repo} =
      Repo.start_link(name: nil, pool: DBConnection.ConnectionPool, pool_size: 4)

    Process.unlink(race_repo)

    fixture =
      on_repo(race_repo, fn ->
        account = account_fixture("race@#{Ecto.UUID.generate()}.example.test")

        {:ok, purge} =
          AccountLifecycle.request_deletion(account.id, Accounts.account_address(account))

        discard_purge_jobs(purge.id)

        failed =
          purge
          |> AccountPurge.changeset(%{status: "failed", error_message: "retry me"})
          |> Repo.update!()

        %{account: account, domain_id: account.domain_id, purge: failed}
      end)

    on_exit(fn -> cleanup_race_fixture(race_repo, fixture) end)

    barrier_ref = make_ref()
    test_pid = self()

    request_task =
      Task.async(fn ->
        receive do
          {:start_request, ^barrier_ref} ->
            on_repo(race_repo, fn ->
              AccountLifecycle.request_deletion(
                fixture.account.id,
                Accounts.account_address(fixture.account)
              )
            end)
        end
      end)

    handler_id = {__MODULE__, self(), barrier_ref}
    event = Keyword.fetch!(Repo.config(), :telemetry_prefix) ++ [:query]

    :ok =
      :telemetry.attach(
        handler_id,
        event,
        fn _event, _measurements, %{query: query}, {owner, ref, request_pid} ->
          if self() == request_pid and String.contains?(query, "pg_try_advisory_xact_lock") do
            send(owner, {:request_holds_oban_lock, self(), ref})

            receive do
              {:release_oban_lock, ^ref} -> :ok
            after
              5_000 -> :ok
            end
          end
        end,
        {test_pid, barrier_ref, request_task.pid}
      )

    send(request_task.pid, {:start_request, barrier_ref})

    {request_result, retry_result} =
      try do
        assert_receive {:request_holds_oban_lock, request_pid, ^barrier_ref}, 2_000

        retry_task =
          Task.async(fn ->
            on_repo(race_repo, fn -> AccountLifecycle.retry_deletion(fixture.purge.id) end)
          end)

        retry_result = Task.await(retry_task, 5_000)
        send(request_pid, {:release_oban_lock, barrier_ref})
        request_result = Task.await(request_task, 5_000)
        {request_result, retry_result}
      after
        send(request_task.pid, {:release_oban_lock, barrier_ref})
        :telemetry.detach(handler_id)
      end

    assert {:ok, %AccountPurge{id: purge_id}} = request_result
    assert {:ok, %AccountPurge{id: ^purge_id, status: "requested"}} = retry_result

    assert on_repo(race_repo, fn -> incomplete_purge_job_count(purge_id) end) == 1
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
             states: :incomplete
           ]

    assert Oban.Job.unique_states(opts[:unique][:states]) ==
             [:suspended, :available, :scheduled, :executing, :retryable]

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
    purge_id
    |> purge_jobs()
    |> Enum.count(&(&1.state in ~w(suspended available scheduled executing retryable)))
  end

  defp purge_jobs(purge_id) do
    PurgeAccount
    |> purge_job_query(purge_id)
    |> order_by([job], asc: job.id)
    |> Repo.all()
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

  defp on_repo(repo, fun) do
    previous_repo = Repo.put_dynamic_repo(repo)

    try do
      fun.()
    after
      Repo.put_dynamic_repo(previous_repo)
    end
  end

  defp cleanup_race_fixture(race_repo, fixture) do
    if Process.alive?(race_repo) do
      try do
        on_repo(race_repo, fn ->
          PurgeAccount
          |> purge_job_query(fixture.purge.id)
          |> Repo.delete_all()

          Repo.delete_all(from(purge in AccountPurge, where: purge.id == ^fixture.purge.id))
          Repo.delete_all(from(account in Account, where: account.id == ^fixture.account.id))

          Repo.query!("DELETE FROM domains WHERE id = $1", [
            Ecto.UUID.dump!(fixture.domain_id)
          ])
        end)
      after
        if Process.alive?(race_repo), do: Supervisor.stop(race_repo)
      end
    end
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
