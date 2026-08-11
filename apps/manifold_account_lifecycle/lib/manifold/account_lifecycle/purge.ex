defmodule Manifold.AccountLifecycle.Purge do
  @moduledoc false

  defmodule DeleteSavepointRepo do
    @moduledoc false

    alias Manifold.Repo

    def one(query), do: Repo.one(query)
    def preload(struct, associations), do: Repo.preload(struct, associations)
    def delete(struct), do: Repo.delete(struct, mode: :savepoint)
  end

  import Ecto.Query

  alias Manifold.AccountLifecycle.Schema.{AccountPurge, PurgeDelivery, PurgeObject}
  alias Manifold.Accounts
  alias Manifold.Connectors
  alias Manifold.Connectors.ActivityLog
  alias Manifold.Core.Error
  alias Manifold.Ingest
  alias Manifold.Mail
  alias Manifold.Outbound
  alias Manifold.Repo
  alias Manifold.Storage.{BlobStore, RawStore, Spool}

  @batch_size 250
  @attachment_batch_size @batch_size - 2
  @discovery_sources ~w(mail ingest connectors)
  @drain_sources ~w(connectors outbound ingest)

  @type result ::
          :ok
          | {:snooze, 1 | 5}
          | {:cancel, :account_purge_not_found}
          | {:discard, atom()}
          | {:error, atom()}

  @spec run(Ecto.UUID.t(), Oban.Job.t()) :: result()
  def run(purge_id, %Oban.Job{} = job) do
    with {:ok, stage} <- ensure_running(purge_id) do
      purge_id
      |> dispatch(stage, job)
      |> handle_result(purge_id, job)
    else
      :ok -> :ok
      {:cancel, :account_purge_not_found} = cancelled -> cancelled
      {:discard, _reason} = discarded -> discarded
      {:error, reason} -> handle_error(purge_id, job, reason)
    end
  rescue
    error in [DBConnection.ConnectionError, Postgrex.Error, Ecto.ConstraintError] ->
      handle_error(purge_id, job, error)
  end

  defp ensure_running(purge_id) do
    Repo.transaction(fn ->
      case locked_purge(Repo, purge_id) do
        nil ->
          {:cancel, :account_purge_not_found}

        %AccountPurge{status: "completed"} ->
          :ok

        %AccountPurge{status: "failed"} ->
          {:discard, :account_purge_failed}

        %AccountPurge{status: "requested"} = purge ->
          now = DateTime.utc_now()

          case update_purge(Repo, purge, %{
                 status: "running",
                 started_at: purge.started_at || now,
                 error_class: nil,
                 error_code: nil,
                 error_message: nil
               }) do
            {:ok, running} -> {:ok, running.stage}
            {:error, reason} -> Repo.rollback(reason)
          end

        %AccountPurge{status: "running", stage: stage} ->
          {:ok, stage}
      end
    end)
    |> unwrap_transaction()
  end

  defp dispatch(purge_id, "discover", _job), do: discover(purge_id)
  defp dispatch(purge_id, "drain", _job), do: drain(purge_id)
  defp dispatch(purge_id, "connectors", job), do: connectors(purge_id, job)
  defp dispatch(purge_id, "outbound", _job), do: outbound(purge_id)
  defp dispatch(purge_id, "mailbox_copy", _job), do: mailbox_copy(purge_id)
  defp dispatch(purge_id, "orphan_payloads", job), do: orphan_payloads(purge_id, job)
  defp dispatch(purge_id, "objects", _job), do: objects(purge_id)
  defp dispatch(purge_id, "finalize", _job), do: finalize(purge_id)
  defp dispatch(_purge_id, "completed", _job), do: :ok

  defp discover(purge_id) do
    with_stage(purge_id, "discover", fn repo, purge ->
      progress = discovery_progress(purge.progress)

      case first_incomplete(@discovery_sources, progress) do
        nil ->
          advance_result(repo, purge, "drain")

        source ->
          cursor = Map.get(progress, source)
          %{ids: ids, done?: done?} = result = discovery_call(source, purge.mailbox_id, cursor)
          inserted = insert_delivery_work(repo, purge.id, ids)
          next_cursor = Map.get(result, :next) || List.last(ids) || cursor

          progress =
            progress
            |> Map.put(source, next_cursor)
            |> maybe_complete_source(source, done?)

          attrs = %{
            progress: progress,
            discovered_deliveries: purge.discovered_deliveries + inserted
          }

          with {:ok, updated} <- update_purge(repo, purge, attrs) do
            if all_complete?(@discovery_sources, progress) do
              advance_result(repo, updated, "drain")
            else
              {:snooze, 1}
            end
          end
      end
    end)
  end

  defp drain(purge_id) do
    with_stage(purge_id, "drain", fn repo, purge ->
      progress = drain_progress(purge.progress)

      case first_incomplete(@drain_sources, progress) do
        nil ->
          advance_result(repo, purge, "connectors")

        source ->
          case drain_call(source, purge, progress) do
            {:snooze, 5} ->
              {:snooze, 5}

            {result, cursor, source_done?} ->
              progress =
                progress
                |> Map.put("source", source)
                |> maybe_put_cursor(cursor)
                |> maybe_complete_source(source, result.done? and source_done?)

              with {:ok, updated} <- update_purge(repo, purge, %{progress: progress}) do
                if all_complete?(@drain_sources, progress) do
                  advance_result(repo, updated, "connectors")
                else
                  {:snooze, 1}
                end
              end
          end
      end
    end)
  end

  defp connectors(purge_id, job) do
    with_stage(purge_id, "connectors", fn repo, purge ->
      result = Connectors.purge_account_batch(repo, purge.mailbox_id, @batch_size)

      if injected_after_connector_delete_before_object_outbox?(job) do
        repo.rollback(:injected_after_connector_delete_before_object_outbox)
      end

      _inserted = insert_object_work(repo, purge.id, "activity_log", result.activity_log_ids)

      if result.done? do
        advance_result(repo, purge, "outbound")
      else
        {:snooze, 1}
      end
    end)
  end

  defp outbound(purge_id) do
    with_stage(purge_id, "outbound", fn repo, purge ->
      if Outbound.purge_account_batch(purge.mailbox_id, @batch_size).done? do
        advance_result(repo, purge, "mailbox_copy")
      else
        {:snooze, 1}
      end
    end)
  end

  defp mailbox_copy(purge_id) do
    with_stage(purge_id, "mailbox_copy", fn repo, purge ->
      progress = mailbox_copy_progress(purge.progress)

      cond do
        not progress["mail"] ->
          result = Mail.delete_mailbox_entries_batch(purge.mailbox_id, @batch_size)
          persist_mailbox_copy_result(repo, purge, progress, "mail", result.done?)

        not progress["ingest"] ->
          result = Ingest.delete_mailbox_links_batch(purge.mailbox_id, @batch_size)
          persist_mailbox_copy_result(repo, purge, progress, "ingest", result.done?)

        true ->
          advance_result(repo, purge, "orphan_payloads")
      end
    end)
  end

  defp orphan_payloads(purge_id, job) do
    result =
      with_stage(purge_id, "orphan_payloads", fn repo, purge ->
        candidates =
          PurgeDelivery
          |> where([work], work.purge_id == ^purge.id and work.disposition == "pending")
          |> order_by([work], asc: work.inbound_delivery_id, asc: work.id)
          |> limit(1)
          |> lock("FOR UPDATE SKIP LOCKED")
          |> repo.all()

        case candidates do
          [] ->
            advance_result(repo, purge, "objects")

          [work] ->
            process_orphan_candidate(repo, purge, work)
        end
      end)

    if result == {:snooze, 1} and injected_after_orphan_commit?(job) do
      {:error, :injected_after_orphan_payload_commit}
    else
      result
    end
  end

  defp objects(purge_id) do
    with_stage(purge_id, "objects", fn repo, purge ->
      rows =
        PurgeObject
        |> where([work], work.purge_id == ^purge.id and work.status == "pending")
        |> order_by([work], asc: work.kind, asc: work.object_key, asc: work.id)
        |> limit(@batch_size)
        |> lock("FOR UPDATE SKIP LOCKED")
        |> repo.all()

      case rows do
        [] ->
          advance_result(repo, purge, "finalize")

        rows ->
          {deleted, error} = process_objects(repo, rows)

          case update_purge(repo, purge, %{deleted_objects: purge.deleted_objects + deleted}) do
            {:ok, _updated} -> if(error, do: {:error, error}, else: {:snooze, 1})
            {:error, reason} -> repo.rollback(reason)
          end
      end
    end)
  end

  defp finalize(purge_id) do
    with_stage(purge_id, "finalize", fn repo, purge ->
      progress = finalize_progress(purge.progress)

      case progress["phase"] do
        "discover" -> finalize_discover(repo, purge, progress)
        "drain" -> finalize_drain(repo, purge, progress)
        "verify" -> finalize_verify(repo, purge)
      end
    end)
  end

  defp finalize_discover(repo, purge, progress) do
    case first_incomplete(@discovery_sources, progress) do
      nil ->
        update_purge(repo, purge, %{
          progress: %{"phase" => "drain", "complete_sources" => []}
        })
        |> update_to_snooze()

      source ->
        cursor = Map.get(progress, source)
        %{ids: ids, done?: done?} = result = discovery_call(source, purge.mailbox_id, cursor)
        inserted = insert_delivery_work(repo, purge.id, ids)
        next_cursor = Map.get(result, :next) || List.last(ids) || cursor

        progress =
          progress
          |> Map.put(source, next_cursor)
          |> maybe_complete_source(source, done?)

        attrs = %{
          progress: progress,
          discovered_deliveries: purge.discovered_deliveries + inserted
        }

        update_purge(repo, purge, attrs) |> update_to_snooze()
    end
  end

  defp finalize_drain(repo, purge, progress) do
    case first_incomplete(@drain_sources, progress) do
      nil ->
        update_purge(repo, purge, %{progress: %{"phase" => "verify"}})
        |> update_to_snooze()

      source ->
        case drain_call(source, purge, progress) do
          {:snooze, 5} ->
            {:snooze, 5}

          {result, cursor, source_done?} ->
            progress =
              progress
              |> Map.put("source", source)
              |> maybe_put_cursor(cursor)
              |> maybe_complete_source(source, result.done? and source_done?)

            update_purge(repo, purge, %{progress: progress}) |> update_to_snooze()
        end
    end
  end

  defp finalize_verify(repo, purge) do
    pending_deliveries? =
      repo.exists?(
        where(PurgeDelivery, [work], work.purge_id == ^purge.id and work.disposition == "pending")
      )

    pending_objects? =
      repo.exists?(
        where(PurgeObject, [work], work.purge_id == ^purge.id and work.status == "pending")
      )

    cond do
      Connectors.account_data_remaining?(purge.mailbox_id) ->
        advance_result(repo, purge, "connectors")

      Outbound.account_data_remaining?(purge.mailbox_id) ->
        advance_result(repo, purge, "outbound")

      Mail.account_data_remaining?(purge.mailbox_id) ->
        advance_result(repo, purge, "mailbox_copy")

      Ingest.account_data_remaining?(purge.mailbox_id) ->
        advance_result(repo, purge, "mailbox_copy")

      pending_deliveries? ->
        advance_result(repo, purge, "orphan_payloads")

      pending_objects? ->
        advance_result(repo, purge, "objects")

      true ->
        complete_purge(repo, purge)
    end
  end

  defp complete_purge(repo, purge) do
    case delete_account_with_savepoint(repo, purge.mailbox_id) do
      {:ok, _account} ->
        repo.delete_all(where(PurgeDelivery, [work], work.purge_id == ^purge.id))
        repo.delete_all(where(PurgeObject, [work], work.purge_id == ^purge.id))

        attrs = %{
          status: "completed",
          stage: "completed",
          progress: %{},
          error_class: nil,
          error_code: nil,
          error_message: nil,
          completed_at: DateTime.utc_now()
        }

        case update_purge(repo, purge, attrs) do
          {:ok, _completed} -> :ok
          {:error, reason} -> repo.rollback(reason)
        end

      {:error, %Ecto.Changeset{} = changeset} ->
        case owning_stage(changeset) do
          nil -> {:error, changeset}
          stage -> advance_result(repo, purge, stage)
        end

      {:error, reason} ->
        {:error, reason}

      {:constraint, constraint} ->
        case owning_stage(constraint) do
          nil ->
            {:error, {:unrouted_local_constraint, constraint}}

          stage ->
            advance_result(repo, purge, stage)
        end
    end
  end

  defp delete_account_with_savepoint(repo, mailbox_id) do
    case repo.transaction(
           fn ->
             try do
               case Accounts.delete_purging_account(DeleteSavepointRepo, mailbox_id) do
                 {:ok, account} -> {:ok, account}
                 {:error, reason} -> {:error, reason}
               end
             rescue
               error in Ecto.ConstraintError -> {:constraint, error.constraint}
             end
           end,
           mode: :savepoint
         ) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp discovery_call("mail", mailbox_id, cursor),
    do: Mail.list_account_delivery_ids(mailbox_id, cursor, @batch_size)

  defp discovery_call("ingest", mailbox_id, cursor),
    do: Ingest.list_account_delivery_ids(mailbox_id, cursor, @batch_size)

  defp discovery_call("connectors", mailbox_id, cursor),
    do: Connectors.list_account_delivery_ids(mailbox_id, cursor, @batch_size)

  defp drain_call("connectors", purge, _progress) do
    case Connectors.cancel_account_jobs(purge.mailbox_id, @batch_size) do
      {:snooze, 5} -> {:snooze, 5}
      result -> {result, nil, true}
    end
  end

  defp drain_call("outbound", purge, _progress) do
    case Outbound.cancel_account_jobs(purge.mailbox_id, @batch_size) do
      {:snooze, 5} -> {:snooze, 5}
      result -> {result, nil, true}
    end
  end

  defp drain_call("ingest", purge, progress) do
    cursor = Map.get(progress, "cursor")

    query =
      PurgeDelivery
      |> where([work], work.purge_id == ^purge.id)
      |> order_by([work], asc: work.inbound_delivery_id)
      |> limit(@batch_size)

    query =
      if cursor do
        where(query, [work], work.inbound_delivery_id > ^cursor)
      else
        query
      end

    ids = Repo.all(from(work in query, select: work.inbound_delivery_id))

    case Ingest.cancel_delivery_jobs(ids, @batch_size) do
      {:snooze, 5} ->
        {:snooze, 5}

      result ->
        next_cursor = if result.done?, do: List.last(ids) || cursor, else: cursor
        {result, next_cursor, length(ids) < @batch_size}
    end
  end

  defp insert_delivery_work(_repo, _purge_id, []), do: 0

  defp insert_delivery_work(repo, purge_id, delivery_ids) do
    timestamp = now()

    rows =
      Enum.map(delivery_ids, fn delivery_id ->
        %{
          id: Ecto.UUID.generate(),
          purge_id: purge_id,
          inbound_delivery_id: delivery_id,
          disposition: "pending",
          inserted_at: timestamp,
          updated_at: timestamp
        }
      end)

    {inserted, _rows} =
      repo.insert_all(PurgeDelivery, rows,
        on_conflict: :nothing,
        conflict_target: [:purge_id, :inbound_delivery_id]
      )

    inserted
  end

  defp insert_object_work(_repo, _purge_id, _kind, []), do: 0

  defp insert_object_work(repo, purge_id, kind, object_keys) do
    timestamp = now()

    rows =
      object_keys
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.map(fn object_key ->
        %{
          id: Ecto.UUID.generate(),
          purge_id: purge_id,
          kind: kind,
          object_key: object_key,
          status: "pending",
          attempts: 0,
          inserted_at: timestamp,
          updated_at: timestamp
        }
      end)

    case rows do
      [] ->
        0

      rows ->
        {inserted, _rows} =
          repo.insert_all(PurgeObject, rows,
            on_conflict: :nothing,
            conflict_target: [:purge_id, :kind, :object_key]
          )

        inserted
    end
  end

  defp delivery_owned?(delivery_id) do
    Mail.delivery_owned?(delivery_id) or Ingest.delivery_owned?(delivery_id) or
      Connectors.delivery_owned?(delivery_id)
  end

  defp process_orphan_candidate(repo, purge, work) do
    if delivery_owned?(work.inbound_delivery_id) do
      {1, _rows} =
        work
        |> where_work_id()
        |> repo.update_all(set: [disposition: "shared_retained", updated_at: now()])

      case update_purge(repo, purge, %{
             progress: %{},
             shared_retained_deliveries: purge.shared_retained_deliveries + 1
           }) do
        {:ok, _updated} -> {:snooze, 1}
        {:error, reason} -> repo.rollback(reason)
      end
    else
      attachment_cursor =
        if purge.progress["delivery_cursor"] == work.inbound_delivery_id do
          purge.progress["attachment_cursor"]
        end

      batch =
        Mail.attachment_object_keys_batch(
          repo,
          work.inbound_delivery_id,
          attachment_cursor,
          @attachment_batch_size
        )

      insert_object_work(repo, purge.id, "blob", batch.keys)

      if batch.done? do
        finish_orphan_delivery(repo, purge, work)
      else
        progress = %{
          "delivery_cursor" => work.inbound_delivery_id,
          "attachment_cursor" => batch.next
        }

        update_purge(repo, purge, %{progress: progress}) |> update_to_snooze()
      end
    end
  end

  defp finish_orphan_delivery(repo, purge, work) do
    case Ingest.delete_orphan_delivery(repo, work.inbound_delivery_id) do
      {:ok, candidates} ->
        insert_object_work(repo, purge.id, "raw", [candidates.raw_object_key])
        insert_object_work(repo, purge.id, "spool", [candidates.spool_bundle_path])

        {1, _rows} =
          work
          |> where_work_id()
          |> repo.update_all(set: [disposition: "purged", updated_at: now()])

        case update_purge(repo, purge, %{
               progress: %{},
               purged_deliveries: purge.purged_deliveries + 1
             }) do
          {:ok, _updated} -> {:snooze, 1}
          {:error, reason} -> repo.rollback(reason)
        end

      {:error, reason} ->
        repo.rollback(reason)
    end
  end

  defp process_objects(repo, rows) do
    Enum.reduce_while(rows, {0, nil}, fn row, {deleted, nil} ->
      case process_object(repo, row) do
        {:ok, deleted?} ->
          {1, _rows} =
            row
            |> object_work_id_query()
            |> repo.update_all(set: [status: "completed", last_error: nil, updated_at: now()])

          {:cont, {deleted + if(deleted?, do: 1, else: 0), nil}}

        {:error, reason} ->
          safe = safe_error(reason)

          {1, _rows} =
            row
            |> object_work_id_query()
            |> repo.update_all(
              set: [
                attempts: row.attempts + 1,
                last_error: bounded_error(safe.code, safe.message),
                updated_at: now()
              ]
            )

          {:halt, {deleted, reason}}
      end
    end)
  end

  defp process_object(repo, %PurgeObject{kind: "blob", object_key: key}) do
    :ok = Mail.lock_blob_object_keys(repo, [key])

    if Mail.blob_referenced?(key) do
      {:ok, false}
    else
      delete_result(BlobStore.delete(key))
    end
  end

  defp process_object(_repo, %PurgeObject{kind: "raw", object_key: key}) do
    if Ingest.raw_object_referenced?(key) do
      {:ok, false}
    else
      delete_result(RawStore.delete(key))
    end
  end

  defp process_object(_repo, %PurgeObject{kind: "spool", object_key: path}) do
    if Ingest.spool_path_referenced?(path) do
      {:ok, false}
    else
      delete_result(Spool.remove_ready_bundle(path))
    end
  end

  defp process_object(_repo, %PurgeObject{kind: "activity_log", object_key: account_id}) do
    delete_result(ActivityLog.delete_account(account_id))
  end

  defp delete_result(:ok), do: {:ok, true}
  defp delete_result({:error, reason}), do: {:error, reason}

  defp persist_mailbox_copy_result(repo, purge, progress, source, done?) do
    progress = if done?, do: Map.put(progress, source, true), else: progress

    with {:ok, updated} <- update_purge(repo, purge, %{progress: progress}) do
      if progress["mail"] and progress["ingest"] do
        advance_result(repo, updated, "orphan_payloads")
      else
        {:snooze, 1}
      end
    end
  end

  defp discovery_progress(progress) do
    Map.merge(%{"complete_sources" => []}, progress || %{})
  end

  defp drain_progress(progress) do
    Map.merge(%{"complete_sources" => [], "source" => "connectors"}, progress || %{})
  end

  defp mailbox_copy_progress(progress) do
    Map.merge(%{"mail" => false, "ingest" => false}, progress || %{})
  end

  defp finalize_progress(%{"phase" => phase} = progress)
       when phase in ["discover", "drain", "verify"],
       do: Map.put_new(progress, "complete_sources", [])

  defp finalize_progress(_progress), do: %{"phase" => "discover", "complete_sources" => []}

  defp first_incomplete(sources, progress) do
    completed = Map.get(progress, "complete_sources", [])
    Enum.find(sources, &(&1 not in completed))
  end

  defp maybe_complete_source(progress, _source, false), do: progress

  defp maybe_complete_source(progress, source, true) do
    Map.update(progress, "complete_sources", [source], fn completed ->
      if source in completed, do: completed, else: completed ++ [source]
    end)
  end

  defp all_complete?(sources, progress) do
    completed = Map.get(progress, "complete_sources", [])
    Enum.all?(sources, &(&1 in completed))
  end

  defp maybe_put_cursor(progress, nil), do: Map.delete(progress, "cursor")
  defp maybe_put_cursor(progress, cursor), do: Map.put(progress, "cursor", cursor)

  defp update_to_snooze({:ok, _purge}), do: {:snooze, 1}
  defp update_to_snooze({:error, reason}), do: {:error, reason}

  defp with_stage(purge_id, expected_stage, fun) do
    Repo.transaction(fn ->
      case locked_purge(Repo, purge_id) do
        nil ->
          {:cancel, :account_purge_not_found}

        %AccountPurge{status: "completed"} ->
          :ok

        %AccountPurge{status: "failed"} ->
          {:discard, :account_purge_failed}

        %AccountPurge{status: "running", stage: ^expected_stage} = purge ->
          fun.(Repo, purge)

        %AccountPurge{status: "running"} ->
          {:snooze, 1}
      end
    end)
    |> unwrap_transaction()
  end

  defp locked_purge(repo, purge_id) do
    AccountPurge
    |> where([purge], purge.id == ^purge_id)
    |> lock("FOR UPDATE")
    |> repo.one()
  end

  defp advance(repo, purge, next_stage) do
    update_purge(repo, purge, %{stage: next_stage, progress: %{}})
  end

  defp advance_result(repo, purge, next_stage) do
    case advance(repo, purge, next_stage) do
      {:ok, _updated} -> {:snooze, 1}
      {:error, reason} -> {:error, reason}
    end
  end

  defp update_purge(repo, purge, attrs) do
    purge
    |> AccountPurge.changeset(attrs)
    |> repo.update()
  end

  defp where_work_id(work) do
    where(
      PurgeDelivery,
      [candidate],
      candidate.id == ^work.id and candidate.disposition == "pending"
    )
  end

  defp object_work_id_query(work) do
    where(PurgeObject, [candidate], candidate.id == ^work.id and candidate.status == "pending")
  end

  defp unwrap_transaction({:ok, result}), do: result
  defp unwrap_transaction({:error, reason}), do: {:error, reason}

  defp handle_result({:error, reason}, purge_id, job), do: handle_error(purge_id, job, reason)
  defp handle_result(result, _purge_id, _job), do: result

  defp handle_error(purge_id, job, reason) do
    safe = safe_error(reason)

    if safe.class == :permanent or exhausted?(job) do
      mark_failed(purge_id, safe)
      {:discard, safe.code}
    else
      {:error, safe.code}
    end
  end

  defp mark_failed(purge_id, safe) do
    Repo.transaction(fn ->
      case locked_purge(Repo, purge_id) do
        %AccountPurge{status: status} = purge when status in ["requested", "running"] ->
          update_purge(Repo, purge, %{
            status: "failed",
            error_class: Atom.to_string(safe.class),
            error_code: Atom.to_string(safe.code),
            error_message: safe.message
          })

        _terminal_or_missing ->
          :ok
      end
    end)
  end

  defp safe_error(%Error{class: class, reason: reason}) do
    class = if class in [:temporary, :permanent], do: class, else: :temporary
    %{class: class, code: safe_atom(reason), message: generic_message(class)}
  end

  defp safe_error(%Ecto.Changeset{}) do
    %{class: :permanent, code: :local_invariant_failed, message: generic_message(:permanent)}
  end

  defp safe_error(%Ecto.ConstraintError{}) do
    %{class: :permanent, code: :local_invariant_failed, message: generic_message(:permanent)}
  end

  defp safe_error({:unrouted_local_constraint, _constraint}) do
    %{class: :permanent, code: :local_invariant_failed, message: generic_message(:permanent)}
  end

  defp safe_error(error) when is_struct(error, DBConnection.ConnectionError) do
    %{class: :temporary, code: :database_unavailable, message: generic_message(:temporary)}
  end

  defp safe_error(error) when is_struct(error, Postgrex.Error) do
    %{class: :temporary, code: :database_unavailable, message: generic_message(:temporary)}
  end

  defp safe_error(reason) when reason in [:invalid_key, :invalid_account_id] do
    %{class: :permanent, code: :invalid_local_object, message: generic_message(:permanent)}
  end

  defp safe_error(reason) when is_atom(reason) do
    %{class: :temporary, code: safe_atom(reason), message: generic_message(:temporary)}
  end

  defp safe_error(_reason) do
    %{class: :temporary, code: :local_cleanup_failed, message: generic_message(:temporary)}
  end

  defp safe_atom(reason) when is_atom(reason), do: reason
  defp safe_atom(_reason), do: :local_cleanup_failed

  defp generic_message(:temporary), do: "Temporary local cleanup failure; retry is safe."
  defp generic_message(:permanent), do: "Local cleanup could not satisfy a required invariant."

  defp bounded_error(code, message) do
    (Atom.to_string(code) <> ": " <> message)
    |> binary_part(0, min(byte_size(Atom.to_string(code) <> ": " <> message), 500))
  end

  defp exhausted?(%Oban.Job{attempt: attempt, max_attempts: max_attempts}) do
    is_integer(attempt) and is_integer(max_attempts) and max_attempts > 0 and
      attempt >= max_attempts
  end

  defp injected_after_orphan_commit?(%Oban.Job{meta: meta}) do
    Map.get(meta || %{}, "fail_at") == "after_orphan_payload_commit" or
      Map.get(meta || %{}, :fail_at) == :after_orphan_payload_commit
  end

  defp injected_after_connector_delete_before_object_outbox?(%Oban.Job{meta: meta}) do
    Map.get(meta || %{}, "fail_at") == "after_connector_delete_before_object_outbox" or
      Map.get(meta || %{}, :fail_at) == :after_connector_delete_before_object_outbox
  end

  defp owning_stage(%Ecto.Changeset{} = changeset) do
    Enum.find_value(changeset.constraints, &owning_stage(&1.constraint))
  end

  defp owning_stage(constraint) when is_binary(constraint) do
    cond do
      String.contains?(constraint, "connector") ->
        "connectors"

      String.contains?(constraint, "outbound") ->
        "outbound"

      String.contains?(constraint, ["delivery", "ingress", "mailbox"]) ->
        "mailbox_copy"

      true ->
        nil
    end
  end

  defp now, do: DateTime.utc_now()
end
