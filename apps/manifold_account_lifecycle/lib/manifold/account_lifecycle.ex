defmodule Manifold.AccountLifecycle do
  @moduledoc """
  Coordinates account disablement and durable deletion requests.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias Manifold.AccountLifecycle.Jobs.PurgeAccount
  alias Manifold.AccountLifecycle.Schema.AccountPurge
  alias Manifold.Accounts
  alias Manifold.Connectors
  alias Manifold.Core.Error
  alias Manifold.Repo

  @spec request_deletion(Ecto.UUID.t(), String.t()) ::
          {:ok, AccountPurge.t()} | {:error, :confirmation_mismatch | Error.t() | term()}
  def request_deletion(mailbox_id, confirmation) do
    request_deletion(mailbox_id, confirmation, [])
  end

  @doc false
  @spec request_deletion(Ecto.UUID.t(), String.t(), Keyword.t()) ::
          {:ok, AccountPurge.t()} | {:error, :confirmation_mismatch | Error.t() | term()}
  def request_deletion(mailbox_id, confirmation, opts) do
    now = DateTime.utc_now()

    multi =
      Multi.new()
      |> Multi.run(:account, fn repo, _changes ->
        Accounts.begin_purge(repo, mailbox_id, confirmation, now)
      end)
      |> Multi.run(:purge, fn repo, _changes ->
        insert_or_load_purge(repo, mailbox_id, now)
      end)
      |> Multi.run(:connectors, fn repo, _changes ->
        Connectors.quiesce_account(repo, mailbox_id)
      end)
      |> Multi.run(:before_job_insert, fn _repo, _changes ->
        maybe_fail_before_job_insert(opts)
      end)
      |> Oban.insert(
        :job,
        fn %{purge: purge} -> PurgeAccount.new(%{"purge_id" => purge.id}) end,
        retry: false
      )
      |> Multi.run(:job_validation, fn _repo, %{job: job} ->
        validate_persisted_job(job)
      end)

    case Repo.transaction(multi) do
      {:ok, %{purge: purge}} -> {:ok, purge}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  @spec disable_account(Ecto.UUID.t()) ::
          {:ok, Manifold.Accounts.Schema.Account.t()} | {:error, Error.t() | term()}
  def disable_account(mailbox_id) do
    multi =
      Multi.new()
      |> Multi.run(:account, fn repo, _changes ->
        Accounts.disable_account(repo, mailbox_id)
      end)
      |> Multi.run(:connectors, fn repo, _changes ->
        Connectors.quiesce_account(repo, mailbox_id)
      end)

    case Repo.transaction(multi) do
      {:ok, %{account: account}} -> {:ok, account}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  @spec retry_deletion(Ecto.UUID.t()) ::
          {:ok, AccountPurge.t()} | {:error, Error.t() | Ecto.Changeset.t() | term()}
  def retry_deletion(purge_id) do
    multi =
      Multi.new()
      |> Multi.run(:purge, fn repo, _changes -> lock_failed_purge(repo, purge_id) end)
      |> Multi.run(:mailbox, fn _repo, %{purge: purge} -> ensure_mailbox_purging(purge) end)
      |> Multi.update(:reset, fn %{purge: purge} ->
        AccountPurge.changeset(purge, %{
          status: "requested",
          error_class: nil,
          error_code: nil,
          error_message: nil
        })
      end)
      |> Oban.insert(
        :job,
        fn %{reset: purge} -> PurgeAccount.new(%{"purge_id" => purge.id}) end,
        retry: false
      )
      |> Multi.run(:job_validation, fn _repo, %{job: job} ->
        validate_retry_job(job)
      end)

    case Repo.transaction(multi) do
      {:ok, %{reset: purge}} -> {:ok, purge}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  @spec states_by_mailbox([Ecto.UUID.t()]) :: %{
          optional(Ecto.UUID.t()) => %{
            purge_id: Ecto.UUID.t(),
            status: String.t(),
            stage: String.t(),
            error_message: String.t() | nil
          }
        }
  def states_by_mailbox([]), do: %{}

  def states_by_mailbox(mailbox_ids) when is_list(mailbox_ids) do
    AccountPurge
    |> where([purge], purge.mailbox_id in ^mailbox_ids)
    |> select([purge], {
      purge.mailbox_id,
      purge.id,
      purge.status,
      purge.stage,
      purge.error_message
    })
    |> Repo.all()
    |> Map.new(fn {mailbox_id, purge_id, status, stage, error_message} ->
      {mailbox_id,
       %{
         purge_id: purge_id,
         status: status,
         stage: stage,
         error_message: error_message
       }}
    end)
  end

  defp insert_or_load_purge(repo, mailbox_id, now) do
    case repo.get_by(AccountPurge, mailbox_id: mailbox_id) do
      %AccountPurge{status: status} = purge when status in ["requested", "running"] ->
        {:ok, purge}

      %AccountPurge{status: "failed"} ->
        {:error,
         Error.new(
           :permanent,
           :purge_retry_required,
           "failed account purges must use the retry operation"
         )}

      %AccountPurge{status: "completed"} ->
        {:error,
         Error.new(:permanent, :account_purge_completed, "account purge is already completed")}

      nil ->
        %AccountPurge{inserted_at: now, updated_at: now}
        |> AccountPurge.changeset(%{mailbox_id: mailbox_id})
        |> repo.insert()
    end
  end

  defp maybe_fail_before_job_insert(opts) do
    if Keyword.get(opts, :fail_at) == :before_job_insert do
      {:error,
       Error.new(:temporary, :before_job_insert, "injected failure before purge job insertion")}
    else
      {:ok, :ok}
    end
  end

  defp validate_retry_job(%Oban.Job{conflict?: true, state: "executing"}) do
    {:error,
     Error.new(
       :temporary,
       :purge_job_still_finishing,
       "the previous account purge job is still finishing"
     )}
  end

  defp validate_retry_job(%Oban.Job{} = job), do: validate_persisted_job(job)

  defp validate_persisted_job(%Oban.Job{conflict?: true, id: nil}) do
    {:error,
     Error.new(
       :temporary,
       :purge_job_concurrency,
       "account purge job insertion is contended; retry the operation"
     )}
  end

  defp validate_persisted_job(%Oban.Job{id: id} = job) when is_integer(id), do: {:ok, job}

  defp validate_persisted_job(%Oban.Job{}) do
    {:error,
     Error.new(
       :temporary,
       :purge_job_concurrency,
       "account purge job was not durably persisted; retry the operation"
     )}
  end

  defp lock_failed_purge(repo, purge_id) do
    query =
      AccountPurge
      |> where([purge], purge.id == ^purge_id)
      |> lock("FOR UPDATE")

    case repo.one(query) do
      nil ->
        {:error, Error.new(:permanent, :account_purge_not_found, "account purge not found")}

      %AccountPurge{status: "failed"} = purge ->
        {:ok, purge}

      %AccountPurge{} ->
        {:error,
         Error.new(
           :permanent,
           :invalid_state_transition,
           "only failed account purges may be retried"
         )}
    end
  end

  defp ensure_mailbox_purging(%AccountPurge{mailbox_id: mailbox_id}) do
    case Accounts.get_account(mailbox_id) do
      %{purge_requested_at: %DateTime{}} = account ->
        {:ok, account}

      _missing_or_not_purging ->
        {:error,
         Error.new(:permanent, :account_not_purging, "account deletion has not been requested")}
    end
  end
end
