defmodule Manifold.Connectors.ICloud do
  @moduledoc "Independent, encrypted iCloud contacts and calendar connections."
  import Ecto.Query
  alias Manifold.Connectors.Crypto
  alias Manifold.Connectors.Jobs.SyncICloud
  alias Manifold.Data.Schema.ICloudConnection
  alias Manifold.Repo

  @public ~w(id apple_id enabled contacts_enabled calendars_enabled generation contacts_status contacts_error contacts_synced_at calendars_status calendars_error calendars_synced_at next_sync_at)a
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
          connection =
            insert!(
              ICloudConnection.changeset(%ICloudConnection{id: id}, %{
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

      cancel_pending(c.id)

      c =
        update!(c, %{
          password_ciphertext: encrypted,
          contacts_enabled: contacts,
          calendars_enabled: calendars,
          generation: c.generation + 1,
          contacts_status: if(c.enabled, do: "pending", else: "disabled"),
          calendars_status: if(c.enabled, do: "pending", else: "disabled"),
          contacts_error: nil,
          calendars_error: nil,
          sync_owner: nil,
          sync_expires_at: nil,
          next_sync_at: DateTime.utc_now()
        })

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
          contacts_status: if(enabled, do: "pending", else: "disabled"),
          calendars_status: if(enabled, do: "pending", else: "disabled"),
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
      Repo.delete!(c)
      public(c)
    end)
  end

  def sync_now(id) do
    Repo.transaction(fn ->
      c = locked!(id)
      if not c.enabled, do: Repo.rollback(:disabled)
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
          where: c.enabled and (is_nil(c.next_sync_at) or c.next_sync_at <= ^now),
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

  @doc false
  def locked!(id) do
    with {:ok, uuid} <- Ecto.UUID.cast(id),
         %ICloudConnection{} = c <-
           Repo.one(from c in ICloudConnection, where: c.id == ^uuid, lock: "FOR UPDATE") do
      c
    else
      _ -> Repo.rollback(:not_found)
    end
  end

  @doc false
  def update!(c, attrs), do: c |> ICloudConnection.changeset(attrs) |> persist!(:update)

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

    if is_boolean(contacts) and is_boolean(calendars) and (contacts or calendars),
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
