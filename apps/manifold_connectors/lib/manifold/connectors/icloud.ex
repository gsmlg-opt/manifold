defmodule Manifold.Connectors.ICloud do
  @moduledoc "Account-owned, encrypted iCloud contacts and calendar synchronization."
  import Ecto.Query
  alias Manifold.Connectors.Crypto
  alias Manifold.Connectors.Jobs.SyncICloud

  alias Manifold.Data.Schema.{
    ICloudConnection,
    DAVCollection,
    DAVResource,
    Contact,
    Calendar,
    CalendarEvent
  }

  alias Manifold.Data.SyncState
  alias Manifold.Accounts
  alias Manifold.Repo

  @public ~w(id account_id default_contacts_collection_id apple_id enabled contacts_enabled calendars_enabled generation contacts_status contacts_error contacts_synced_at calendars_status calendars_error calendars_synced_at next_sync_at)a
  @incomplete ~w(available scheduled executing retryable)

  def list_connections do
    Repo.all(
      from c in ICloudConnection,
        order_by: [asc: c.inserted_at, asc: c.id],
        select: map(c, ^@public)
    )
  end

  def connect(attrs) when is_map(attrs) do
    apple_id = value(attrs, :apple_id, "")
    password = value(attrs, :app_password, "")

    with true <- valid_credentials?(apple_id, password),
         {:ok, contacts, calendars} <- services(attrs, true, true) do
      id = Ecto.UUID.generate()

      with {:ok, encrypted} <- Crypto.encrypt(password, "icloud:#{id}:app_password") do
        Repo.transaction(fn ->
          account_id = value(attrs, :account_id, nil)
          if is_nil(account_id), do: Repo.rollback(:account_required)
          lock_account!(account_id)

          connection =
            insert!(
              ICloudConnection.changeset(%ICloudConnection{id: id}, %{
                account_id: account_id,
                apple_id: String.trim(apple_id),
                password_ciphertext: encrypted,
                contacts_enabled: contacts,
                calendars_enabled: calendars,
                next_sync_at: DateTime.utc_now()
              })
            )

          {_job, _new?} = queue_locked(connection)
          public(connection)
        end)
      else
        _ -> {:error, :encryption_unavailable}
      end
    else
      false -> {:error, :invalid_credentials}
      error -> error
    end
  end

  def connect(_), do: {:error, :invalid_credentials}

  def update_connection(id, attrs) when is_map(attrs) do
    Repo.transaction(fn ->
      c = locked!(id)

      {contacts, calendars} =
        case services(attrs, c.contacts_enabled, c.calendars_enabled) do
          {:ok, contacts, calendars} -> {contacts, calendars}
          _ -> Repo.rollback(:invalid_services)
        end

      password = value(attrs, :app_password, "")

      encrypted =
        cond do
          password == "" or is_nil(password) ->
            c.password_ciphertext

          valid_credentials?(c.apple_id, password) ->
            case Crypto.encrypt(password, "icloud:#{c.id}:app_password") do
              {:ok, enc} -> enc
              _ -> Repo.rollback(:encryption_unavailable)
            end

          true ->
            Repo.rollback(:invalid_credentials)
        end

      destination =
        value(attrs, :default_contacts_collection_id, c.default_contacts_collection_id)

      destination = if destination == "", do: nil, else: destination
      validate_destination!(c, destination)
      cancel_pending(c.id)

      c =
        update!(c, %{
          default_contacts_collection_id: destination,
          password_ciphertext: encrypted,
          contacts_enabled: contacts,
          calendars_enabled: calendars,
          generation: c.generation + 1,
          contacts_status: if(c.enabled and contacts, do: "pending", else: "disabled"),
          calendars_status: if(c.enabled and calendars, do: "pending", else: "disabled"),
          contacts_error: nil,
          calendars_error: nil,
          sync_owner: nil,
          sync_expires_at: nil,
          next_sync_at: DateTime.utc_now()
        })

      if c.account_id, do: SyncState.enroll_account(c.account_id)
      if c.enabled, do: queue_locked(c)
      public(c)
    end)
  end

  def update_connection(_, _), do: {:error, :invalid_credentials}

  def set_enabled(id, enabled) when is_boolean(enabled) do
    Repo.transaction(fn ->
      c = locked!(id)
      cancel_pending(c.id)

      c =
        update!(c, %{
          enabled: enabled,
          generation: c.generation + 1,
          sync_owner: nil,
          sync_expires_at: nil,
          contacts_status: if(enabled and c.contacts_enabled, do: "pending", else: "disabled"),
          calendars_status: if(enabled and c.calendars_enabled, do: "pending", else: "disabled"),
          contacts_error: nil,
          calendars_error: nil,
          next_sync_at: DateTime.utc_now()
        })

      if enabled, do: queue_locked(c)
      public(c)
    end)
  end

  def disconnect(id) do
    Repo.transaction(fn ->
      c = locked!(id)
      cancel_pending(c.id)

      Repo.update_all(from(r in DAVResource, where: r.connection_id == ^c.id),
        set: [status: "paused"]
      )

      Repo.delete!(c)
      public(c)
    end)
  end

  def sync_now(id) do
    Repo.transaction(fn ->
      c = locked!(id)
      if is_nil(c.account_id), do: Repo.rollback(:account_assignment_required)

      if not c.enabled or (not c.contacts_enabled and not c.calendars_enabled),
        do: Repo.rollback(:disabled)

      if rate_limited?(c), do: Repo.rollback(:rate_limited)
      if not syncable?(c), do: Repo.rollback(:reconnect_required)
      {job, _} = queue_locked(c)
      job
    end)
  end

  def enqueue_due_syncs do
    now = DateTime.utc_now()

    ids =
      Repo.all(
        from c in ICloudConnection,
          where:
            not is_nil(c.account_id) and c.enabled and
              (is_nil(c.next_sync_at) or c.next_sync_at <= ^now),
          select: c.id,
          order_by: c.id,
          limit: 500
      )

    Enum.reduce_while(ids, {:ok, 0}, fn id, {:ok, count} ->
      case Repo.transaction(fn ->
             c = locked!(id)
             due = is_nil(c.next_sync_at) or DateTime.compare(c.next_sync_at, now) != :gt

             if c.enabled and due and syncable?(c) do
               {_job, inserted?} = queue_locked(c)
               if inserted?, do: 1, else: 0
             else
               0
             end
           end) do
        {:ok, added} -> {:cont, {:ok, count + added}}
        {:error, :not_found} -> {:cont, {:ok, count}}
        {:error, _} -> {:halt, {:error, :enqueue_failed}}
      end
    end)
  end

  def for_account(account_id) do
    case Repo.get_by(ICloudConnection, account_id: account_id) do
      nil -> nil
      connection -> public(connection)
    end
  end

  def collections(id, kind \\ nil) do
    query =
      from(c in DAVCollection, where: c.connection_id == ^id, order_by: [asc: c.name, asc: c.id])

    query = if kind, do: from(c in query, where: c.kind == ^kind), else: query
    Repo.all(query)
  end

  def attach(id, account_id) do
    Repo.transaction(fn ->
      lock_account!(account_id)
      c = locked!(id)
      if c.account_id && c.account_id != account_id, do: Repo.rollback(:already_assigned)

      c =
        update!(c, %{
          account_id: account_id,
          generation: c.generation + 1,
          sync_owner: nil,
          sync_expires_at: nil
        })

      Repo.update_all(from(r in DAVResource, where: r.connection_id == ^c.id),
        set: [account_id: account_id]
      )

      collection_ids =
        Repo.all(from(d in DAVCollection, where: d.connection_id == ^c.id, select: d.id))

      Repo.update_all(from(r in Contact, where: r.collection_id in ^collection_ids),
        set: [account_id: account_id]
      )

      Repo.update_all(from(r in Calendar, where: r.collection_id in ^collection_ids),
        set: [account_id: account_id]
      )

      queue_locked(c)
      public(c)
    end)
  end

  @doc false
  def quiesce_account(repo, account_id) do
    # The orchestrating AccountLifecycle transaction already owns the Account lock.
    Enum.each(
      repo.all(from(c in ICloudConnection, where: c.account_id == ^account_id, order_by: c.id)),
      fn c ->
        c = locked!(c.id)
        cancel_pending(c.id)

        update!(c, %{
          enabled: false,
          generation: c.generation + 1,
          sync_owner: nil,
          sync_expires_at: nil,
          contacts_status: "disabled",
          calendars_status: "disabled"
        })
      end
    )

    :ok
  end

  @doc false
  def account_data_remaining?(repo, account_id) do
    repo.exists?(from(c in ICloudConnection, where: c.account_id == ^account_id)) or
      repo.exists?(from(c in Contact, where: c.account_id == ^account_id)) or
      repo.exists?(from(c in Calendar, where: c.account_id == ^account_id)) or
      repo.exists?(from(r in DAVResource, where: r.account_id == ^account_id)) or
      repo.exists?(account_events_query(account_id))
  end

  @doc false
  def purge_account_batch(repo, account_id, limit) do
    events =
      account_events_query(account_id)
      |> select([e], e.id)
      |> order_by([e], e.id)
      |> limit(^limit)

    queries = [
      {CalendarEvent, events},
      {Contact,
       from(c in Contact,
         where: c.account_id == ^account_id,
         select: c.id,
         order_by: c.id,
         limit: ^limit
       )},
      {DAVResource,
       from(r in DAVResource,
         where: r.account_id == ^account_id,
         select: r.id,
         order_by: r.id,
         limit: ^limit
       )},
      {Calendar,
       from(c in Calendar,
         where: c.account_id == ^account_id,
         select: c.id,
         order_by: c.id,
         limit: ^limit
       )},
      {ICloudConnection,
       from(c in ICloudConnection,
         where: c.account_id == ^account_id,
         select: c.id,
         order_by: c.id,
         limit: ^limit
       )}
    ]

    deleted =
      Enum.reduce_while(queries, 0, fn {schema, query}, _ ->
        case repo.all(query) do
          [] ->
            {:cont, 0}

          ids ->
            {count, _} = repo.delete_all(from(r in schema, where: r.id in ^ids))
            {:halt, count}
        end
      end)

    %{
      deleted: deleted,
      done?: not account_data_remaining?(repo, account_id),
      activity_log_ids: []
    }
  end

  defp account_events_query(account_id) do
    from(e in CalendarEvent,
      left_join: c in Calendar,
      on: c.id == e.calendar_id,
      left_join: r in DAVResource,
      on: r.id == e.resource_id,
      left_join: d in DAVCollection,
      on: d.id == e.collection_id,
      left_join: connection in ICloudConnection,
      on: connection.id == d.connection_id,
      where:
        c.account_id == ^account_id or r.account_id == ^account_id or
          connection.account_id == ^account_id
    )
  end

  @doc false
  def account_active?(%{account_id: nil}), do: false

  def account_active?(%{account_id: id}) do
    case Accounts.get_account(id) do
      %{active: true, purge_requested_at: nil} -> true
      _ -> false
    end
  end

  defp lock_account!(id, active_required \\ true) do
    case Repo.one(from(a in Accounts.Schema.Account, where: a.id == ^id, lock: "FOR UPDATE")) do
      nil ->
        Repo.rollback(:account_not_found)

      account ->
        if active_required and (not account.active or account.purge_requested_at),
          do: Repo.rollback(:account_disabled)

        account
    end
  end

  defp validate_destination!(_, nil), do: :ok

  defp validate_destination!(c, id) do
    case Repo.get(DAVCollection, id) do
      %{connection_id: connection_id, kind: "contacts", can_create: allowed, writable: writable}
      when connection_id == c.id and (allowed == true or (is_nil(allowed) and writable)) ->
        :ok

      _ ->
        Repo.rollback(:invalid_destination)
    end
  end

  @doc false
  def locked!(id) do
    with {:ok, uuid} <- Ecto.UUID.cast(id),
         %ICloudConnection{} = observed <- Repo.get(ICloudConnection, uuid) do
      if observed.account_id, do: lock_account!(observed.account_id, false)

      case Repo.one(from c in ICloudConnection, where: c.id == ^uuid, lock: "FOR UPDATE") do
        %ICloudConnection{} = c -> c
        _ -> Repo.rollback(:not_found)
      end
    else
      _ -> Repo.rollback(:not_found)
    end
  end

  @doc false
  def update!(c, attrs), do: c |> ICloudConnection.changeset(attrs) |> persist!(:update)

  defp queue_locked(%{account_id: nil}), do: {nil, false}
  defp queue_locked(%{contacts_enabled: false, calendars_enabled: false}), do: {nil, false}

  defp queue_locked(c) do
    existing =
      Repo.one(
        from j in Oban.Job,
          where:
            j.worker == "Manifold.Connectors.Jobs.SyncICloud" and j.state in ^@incomplete and
              fragment("?->>'connection_id' = ?", j.args, ^c.id) and
              fragment("?->>'generation' = ?", j.args, ^Integer.to_string(c.generation)),
          order_by: [desc: j.id],
          limit: 1
      )

    job =
      existing ||
        insert!(SyncICloud.new(%{"connection_id" => c.id, "generation" => c.generation}))

    update!(c, %{next_sync_at: DateTime.add(DateTime.utc_now(), 300)})
    {job, is_nil(existing)}
  end

  defp cancel_pending(id) do
    Repo.update_all(
      from(j in Oban.Job,
        where:
          j.worker == "Manifold.Connectors.Jobs.SyncICloud" and
            j.state in ["available", "scheduled", "retryable"] and
            fragment("?->>'connection_id' = ?", j.args, ^id)
      ),
      set: [state: "cancelled", cancelled_at: DateTime.utc_now()]
    )
  end

  defp public(c), do: Map.take(c, @public)
  defp insert!(changeset), do: persist!(changeset, :insert)

  defp persist!(changeset, operation) do
    case apply(Repo, operation, [changeset]) do
      {:ok, value} -> value
      _ -> Repo.rollback(:invalid_configuration)
    end
  end

  defp value(attrs, key, default),
    do: Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))

  defp valid_credentials?(id, password),
    do:
      is_binary(id) and byte_size(id) <= 320 and Regex.match?(~r/\A[^\s:]+\z/u, String.trim(id)) and
        is_binary(password) and String.trim(password) != "" and byte_size(password) <= 256

  defp services(attrs, old_contacts, old_calendars) do
    contacts = boolean(value(attrs, :contacts_enabled, old_contacts))
    calendars = boolean(value(attrs, :calendars_enabled, old_calendars))

    if is_boolean(contacts) and is_boolean(calendars),
      do: {:ok, contacts, calendars},
      else: {:error, :invalid_services}
  end

  defp boolean(value) when value in [true, "true", "1", "on", 1], do: true
  defp boolean(value) when value in [false, "false", "0", 0], do: false
  defp boolean(_), do: nil

  defp syncable?(c),
    do:
      (c.contacts_enabled and c.contacts_status != "reconnect_required") or
        (c.calendars_enabled and c.calendars_status != "reconnect_required")

  @doc false
  def cooldown_seconds(c) do
    limited =
      c.contacts_error == "Rate limited; synchronization will retry." or
        c.calendars_error == "Rate limited; synchronization will retry."

    if limited and c.next_sync_at do
      milliseconds = DateTime.diff(c.next_sync_at, DateTime.utc_now(), :millisecond)
      max(0, div(milliseconds + 999, 1000))
    else
      0
    end
  end

  defp rate_limited?(c), do: cooldown_seconds(c) > 0
end
