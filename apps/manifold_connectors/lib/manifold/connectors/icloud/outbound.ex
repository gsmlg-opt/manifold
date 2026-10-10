defmodule Manifold.Connectors.ICloud.Outbound do
  @moduledoc false
  import Ecto.Query
  alias Manifold.Connectors.ICloud.{Sync, Inbound}
  alias Manifold.Connectors.ICloud
  alias Manifold.Connectors.DAV.{Client, Document, VCard}

  alias Manifold.Data.Schema.{
    DAVResource,
    DAVCollection,
    Contact,
    CalendarEvent,
    Calendar,
    ICloudConnection
  }

  alias Manifold.Repo

  def run(connection, credentials, opts \\ []) do
    now = DateTime.utc_now()

    resources =
      Repo.all(
        from(r in DAVResource,
          where:
            r.connection_id == ^connection.id and r.status != "conflict" and
              (r.desired_revision > r.acknowledged_revision or not is_nil(r.sent_revision)) and
              (is_nil(r.retry_at) or r.retry_at <= ^now),
          order_by: [asc: r.updated_at, asc: r.id],
          limit: 100
        )
      )

    Enum.reduce_while(resources, :ok, fn resource, result ->
      if selected?(connection, resource.kind) do
        case process(connection, resource.id, credentials, opts) do
          {:error, :stale} = error -> {:halt, error}
          {:error, {:rate_limited, _}} = error -> {:halt, error}
          {:error, _} = error -> {:cont, if(result == :ok, do: error, else: result)}
          _ -> {:cont, result}
        end
      else
        {:cont, result}
      end
    end)
  end

  defp process(connection, id, credentials, opts) do
    client = Keyword.get(opts, :client, Client)

    case transaction(connection, id, fn resource -> prepare(resource, connection) end) do
      {:ok, :paused} -> :ok
      {:ok, :done} -> :ok
      {:ok, {:error, reason}} -> {:error, reason}
      {:ok, {:attempt, resource}} -> dispatch(connection, resource, credentials, client, opts)
      {:ok, {:reconcile, resource}} -> reconcile(connection, resource, credentials, client, opts)
      {:error, reason} -> {:error, reason}
    end
  end

  defp prepare(resource, connection) do
    cond do
      resource.sent_revision != nil ->
        {:reconcile, resource}

      not enrolled?(resource) ->
        persist_resource(resource, %{status: "paused"})
        :paused

      resource.desired_revision <= resource.acknowledged_revision ->
        :done

      resource.status == "conflict" ->
        :paused

      true ->
        collection = Repo.get(DAVCollection, resource.collection_id)

        capability =
          cond do
            resource.operation == "delete" -> :can_delete
            is_nil(resource.etag) -> :can_create
            true -> :can_update
          end

        allowed =
          (collection &&
             (Map.get(collection, capability) == true or
                (is_nil(Map.get(collection, capability)) and collection.writable))) and
            (resource.kind != "calendars" or collection.supported_components == [] or
               "VEVENT" in collection.supported_components)

        if allowed do
          case payload(resource) do
            {:ok, body} ->
              operation = if body == :empty, do: "delete", else: resource.operation

              if operation == "delete" and is_nil(resource.etag) do
                persist_resource(resource, %{
                  acknowledged_revision: resource.desired_revision,
                  status: "synced"
                })

                :done
              else
                resource =
                  persist_resource(resource, %{
                    sent_revision: resource.desired_revision,
                    sent_raw: if(body == :empty, do: nil, else: body),
                    sent_contact_values: contact_values(resource),
                    sent_etag: resource.etag,
                    sent_operation: operation,
                    sent_generation: connection.generation,
                    status: "uncertain",
                    last_error: nil,
                    retry_at: nil
                  })

                {:attempt, resource}
              end

            {:error, reason} ->
              persist_resource(resource, %{
                status: "failed",
                last_error:
                  case reason do
                    :scheduling_not_supported ->
                      "Invitation and attendee scheduling are unsupported. Make a local copy to edit."

                    :unsupported_calendar_components ->
                      "This calendar resource contains other components and cannot be safely deleted."

                    _ ->
                      "This document cannot be safely written."
                  end,
                retry_at: DateTime.add(DateTime.utc_now(), 300)
              })

              {:error, :invalid_document}
          end
        else
          persist_resource(resource, %{
            status: "failed",
            last_error: "The iCloud destination is read-only or unavailable.",
            retry_at: DateTime.add(DateTime.utc_now(), 300)
          })

          {:error, :forbidden}
        end
    end
  end

  defp payload(%{kind: "calendars"} = resource) when resource.operation == "delete" do
    Document.delete_calendar(resource.base_raw)
  end

  defp payload(%{operation: "delete"}), do: {:ok, :empty}

  defp payload(%{kind: "contacts"} = resource) do
    case Repo.get_by(Contact, resource_id: resource.id) do
      nil ->
        {:error, :local_record_missing}

      contact ->
        contact = ensure_property_ids(contact)
        Document.contact(resource.base_raw, contact, resource.uid)
    end
  end

  defp payload(%{kind: "calendars"} = resource) do
    events =
      Repo.all(
        from(e in CalendarEvent,
          where: e.resource_id == ^resource.id,
          order_by: [asc: e.recurrence_id, asc: e.uid]
        )
      )

    Enum.reduce_while(events, {:ok, resource.base_raw}, fn event, {:ok, raw} ->
      result =
        if event.deleted_at do
          if raw in [nil, :empty] do
            {:ok, :empty}
          else
            case Document.delete_event(raw, event.uid, event.recurrence_id) do
              {:error, :event_not_found} -> {:ok, raw}
              result -> result
            end
          end
        else
          Document.event(
            if(raw == :empty, do: nil, else: raw),
            event,
            event.uid,
            event.recurrence_id
          )
        end

      case result do
        {:ok, body} -> {:cont, {:ok, body}}
        error -> {:halt, error}
      end
    end)
  end

  defp ensure_property_ids(contact) do
    values =
      Map.new([:emails, :phones, :addresses], fn field ->
        entries =
          Enum.map(Map.fetch!(contact, field), fn entry ->
            if entry["property_id"],
              do: entry,
              else: Map.put(entry, "property_id", "local:" <> Ecto.UUID.generate())
          end)

        {field, entries}
      end)

    Repo.update!(Contact.changeset(contact, values))
  end

  defp contact_values(%{kind: "contacts"} = resource) do
    contact = Repo.get_by!(Contact, resource_id: resource.id)

    Map.new([:emails, :phones, :addresses], fn field ->
      {Atom.to_string(field), Map.fetch!(contact, field)}
    end)
  end

  defp contact_values(_), do: nil

  # Rebase only property identities when a newer local revision is still pending.
  # Immutable attempted values connect old IDs with the server's canonical IDs;
  # local value edits/deletions remain untouched.
  defp rebase_contact(resource, raw, etag) do
    if resource.kind == "contacts" and is_map(resource.sent_contact_values) and is_binary(raw) do
      {:ok, observed} = VCard.parse(raw)
      contact = Repo.get_by!(Contact, resource_id: resource.id)

      values =
        Map.new([:emails, :phones, :addresses], fn field ->
          attempted = Map.get(resource.sent_contact_values, Atom.to_string(field), [])

          {mapping, _} =
            Enum.reduce(attempted, {%{}, Map.fetch!(observed, field)}, fn entry,
                                                                          {mapping, remaining} ->
              match =
                Enum.find(
                  remaining,
                  &(Map.delete(&1, "property_id") == Map.delete(entry, "property_id"))
                )

              if match do
                {Map.put(mapping, entry["property_id"], match["property_id"]),
                 List.delete(remaining, match)}
              else
                {mapping, remaining}
              end
            end)

          entries =
            Enum.map(Map.fetch!(contact, field), fn entry ->
              if id = mapping[entry["property_id"]],
                do: Map.put(entry, "property_id", id),
                else: entry
            end)

          {field, entries}
        end)

      Repo.update!(Contact.changeset(contact, Map.merge(values, %{raw: raw, etag: etag})))
    end
  end

  defp dispatch(connection, resource, credentials, client, opts) do
    # Recheck lifecycle eligibility after payload preparation and before admission.
    case transaction(connection, resource.id, fn current ->
           if current.sent_revision == resource.sent_revision and enrolled?(current),
             do: :admitted,
             else: :paused
         end) do
      {:ok, :admitted} ->
        result =
          if resource.sent_operation == "delete" do
            client.delete_resource(resource.href, credentials, resource.sent_etag, opts)
          else
            client.put_resource(
              resource.href,
              credentials,
              resource.kind,
              resource.sent_raw,
              resource.sent_etag || :create,
              opts
            )
          end

        case result do
          {:ok, _} ->
            reconcile(connection, resource, credentials, client, opts)

          {:error, :conflict} ->
            conflict(connection, resource, credentials, client, opts)

          {:error, :outcome_unknown} ->
            record_failure(connection, resource, :outcome_unknown)
            {:error, :outcome_unknown}

          {:error, reason} ->
            record_failure(connection, resource, reason)
            {:error, reason}
        end

      {:ok, :paused} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp reconcile(connection, resource, credentials, client, opts) do
    case client.get_resource(resource.href, credentials, opts) do
      {:ok, remote} ->
        case transaction(connection, resource.id, fn current ->
               if current.sent_revision != resource.sent_revision, do: Repo.rollback(:stale)

               cond do
                 resource.sent_operation == "delete" and remote == :missing ->
                   acknowledge(current, nil, nil)
                   :done

                 resource.sent_operation == "upsert" and remote != :missing and
                     Document.equivalent?(resource.sent_raw, remote.content) ->
                   acknowledge(current, remote.content, remote.etag)
                   :done

                 unchanged_base?(resource, remote) ->
                   # Resolve the original unknown attempt first. Retry uses the exact
                   # persisted payload and condition, only while still enrolled.
                   if enrolled?(current) do
                     {:retry, current}
                   else
                     clear_attempt(current, %{status: "paused"})
                     :done
                   end

                 true ->
                   set_conflict(current, remote)
                   :done
               end
             end) do
          {:ok, {:retry, current}} ->
            retry_known_base(connection, current, credentials, client, opts)

          {:ok, :done} ->
            :ok

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        record_failure(connection, resource, reason, true)
        {:error, reason}
    end
  end

  defp retry_known_base(connection, resource, credentials, client, opts) do
    # A retry performs at most one write per run. Any lost response is left for
    # a later reconciliation, not recursively replayed in this worker.
    case transaction(connection, resource.id, fn current ->
           if current.sent_revision == resource.sent_revision and enrolled?(current),
             do: :admitted,
             else: :paused
         end) do
      {:ok, :admitted} ->
        result =
          if resource.sent_operation == "delete",
            do: client.delete_resource(resource.href, credentials, resource.sent_etag, opts),
            else:
              client.put_resource(
                resource.href,
                credentials,
                resource.kind,
                resource.sent_raw,
                resource.sent_etag || :create,
                opts
              )

        case result do
          {:ok, _} ->
            case client.get_resource(resource.href, credentials, opts) do
              {:ok, :missing} when resource.sent_operation == "delete" ->
                transaction_result(
                  transaction(connection, resource.id, &acknowledge(&1, nil, nil))
                )

              {:ok, %{content: raw, etag: etag}} ->
                if resource.sent_operation == "upsert" and
                     Document.equivalent?(resource.sent_raw, raw) do
                  transaction_result(
                    transaction(connection, resource.id, &acknowledge(&1, raw, etag))
                  )
                else
                  transaction_result(
                    transaction(
                      connection,
                      resource.id,
                      &set_conflict(&1, %{content: raw, etag: etag})
                    )
                  )
                end

              {:ok, remote} ->
                transaction_result(
                  transaction(connection, resource.id, &set_conflict(&1, remote))
                )

              {:error, reason} ->
                record_failure(connection, resource, reason, true)
                {:error, reason}
            end

          {:error, :conflict} ->
            conflict(connection, resource, credentials, client, opts)

          {:error, reason} ->
            record_failure(connection, resource, reason)
            {:error, reason}
        end

      {:ok, :paused} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp unchanged_base?(resource, :missing), do: is_nil(resource.sent_etag)
  defp unchanged_base?(resource, remote), do: resource.sent_etag == remote.etag

  defp conflict(connection, resource, credentials, client, opts) do
    case client.get_resource(resource.href, credentials, opts) do
      {:ok, remote} ->
        transaction_result(transaction(connection, resource.id, &set_conflict(&1, remote)))

      {:error, reason} ->
        record_failure(connection, resource, reason, true)
        {:error, reason}
    end
  end

  defp acknowledge(resource, raw, etag) do
    ack = resource.sent_revision
    pending = resource.desired_revision > ack

    status =
      cond do
        not enrolled?(resource) -> "paused"
        pending -> "pending"
        true -> "synced"
      end

    if pending, do: rebase_contact(resource, raw, etag)

    if not pending and enrolled?(resource) and is_binary(raw) do
      case Inbound.project(resource, raw, etag, resource.account_id) do
        :ok -> :ok
        _ -> Repo.rollback(:invalid_resource)
      end
    end

    clear_attempt(resource, %{
      base_raw: raw,
      etag: etag,
      acknowledged_revision: ack,
      status: status,
      remote_raw: nil,
      remote_etag: nil,
      last_error: nil,
      retry_at: nil
    })
  end

  defp set_conflict(resource, :missing), do: set_conflict(resource, %{content: nil, etag: nil})

  defp set_conflict(resource, remote) do
    clear_attempt(resource, %{
      status: "conflict",
      remote_raw: remote.content,
      remote_etag: remote.etag,
      last_error: "Both local and iCloud data changed.",
      retry_at: nil
    })
  end

  def resolve(id, choice) when choice in [:local, :remote] do
    Repo.transaction(fn ->
      observed = Repo.get!(DAVResource, id)

      with {:ok, _} <-
             Manifold.Data.SyncState.lock_target(observed.kind, observed.account_id, observed.id) do
        resource = Repo.get!(DAVResource, id)
        if resource.status != "conflict", do: Repo.rollback(:not_conflicted)

        if choice == :remote do
          if resource.remote_raw do
            :ok =
              Inbound.project(
                resource,
                resource.remote_raw,
                resource.remote_etag,
                resource.account_id
              )
          else
            schema = if resource.kind == "contacts", do: Contact, else: CalendarEvent

            Repo.update_all(from(r in schema, where: r.resource_id == ^resource.id),
              set: [deleted_at: DateTime.utc_now()]
            )
          end

          persist_resource(resource, %{
            base_raw: resource.remote_raw,
            etag: resource.remote_etag,
            acknowledged_revision: resource.desired_revision,
            status: "synced",
            remote_raw: nil,
            remote_etag: nil,
            last_error: nil
          })
        else
          persist_resource(resource, %{
            base_raw: resource.remote_raw || resource.base_raw,
            etag: resource.remote_etag,
            status: "pending",
            remote_raw: nil,
            remote_etag: nil,
            last_error: nil,
            retry_at: nil
          })
        end
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp record_failure(connection, resource, reason, force_unknown \\ false) do
    unknown =
      force_unknown or reason in [:outcome_unknown, :timeout, :transport_failure, :missing_etag]

    {message, delay} =
      case reason do
        :unauthorized -> {"iCloud authorization failed; replace the app-specific password.", 300}
        :forbidden -> {"The iCloud destination does not allow this operation.", 300}
        {:rate_limited, seconds} -> {"iCloud rate limited synchronization.", seconds}
        _ -> {"Synchronization failed; local changes were retained.", 300}
      end

    transaction(connection, resource.id, fn current ->
      if reason == :unauthorized or match?({:rate_limited, _}, reason) do
        connection = Repo.get!(ICloudConnection, connection.id)

        {status_field, error_field} =
          if resource.kind == "contacts",
            do: {:contacts_status, :contacts_error},
            else: {:calendars_status, :calendars_error}

        error =
          if reason == :unauthorized,
            do: message,
            else: "Rate limited; synchronization will retry."

        ICloud.update!(connection, %{
          status_field => if(reason == :unauthorized, do: "reconnect_required", else: "failed"),
          error_field => error,
          :next_sync_at => DateTime.add(DateTime.utc_now(), delay)
        })
      end

      attrs = %{
        status: if(unknown, do: "uncertain", else: "failed"),
        last_error: message,
        retry_at: DateTime.add(DateTime.utc_now(), delay)
      }

      if unknown, do: persist_resource(current, attrs), else: clear_attempt(current, attrs)
    end)
  end

  defp transaction(connection, id, fun) do
    Repo.transaction(fn ->
      current_connection = Sync.current!(connection)

      resource =
        Repo.one(
          from(r in DAVResource,
            where: r.id == ^id and r.connection_id == ^connection.id,
            lock: "FOR UPDATE"
          )
        )

      if is_nil(resource), do: Repo.rollback(:stale)
      if selected?(current_connection, resource.kind), do: fun.(resource), else: :paused
    end)
  end

  defp transaction_result({:ok, _}), do: :ok
  defp transaction_result({:error, reason}), do: {:error, reason}

  defp clear_attempt(resource, attrs),
    do:
      persist_resource(
        resource,
        Map.merge(
          %{
            sent_revision: nil,
            sent_raw: nil,
            sent_contact_values: nil,
            sent_etag: nil,
            sent_operation: nil,
            sent_generation: nil
          },
          attrs
        )
      )

  defp persist_resource(resource, attrs), do: Repo.update!(DAVResource.changeset(resource, attrs))
  defp enrolled?(%{kind: "contacts"} = resource), do: Inbound.enrolled?(resource, nil)

  defp enrolled?(%{kind: "calendars"} = resource) do
    case Repo.one(
           from(e in CalendarEvent,
             where: e.resource_id == ^resource.id,
             select: e.calendar_id,
             limit: 1
           )
         ) do
      nil -> false
      id -> Inbound.enrolled?(resource, Repo.get(Calendar, id))
    end
  end

  defp selected?(connection, "contacts"),
    do: connection.contacts_enabled and connection.contacts_status != "reconnect_required"

  defp selected?(connection, "calendars"),
    do: connection.calendars_enabled and connection.calendars_status != "reconnect_required"
end
