defmodule Manifold.Connectors.CalendarSync.ICloud do
  @moduledoc "CalDAV adapter for independently bound local calendars and complete ICS resources."
  alias Manifold.Connectors.CalendarConnections
  alias Manifold.Connectors.DAV.{Client, Document, ICalendar, URL}
  alias Manifold.Data.{CalendarSyncState, Schema.CalendarBinding, Schema.CalendarConnection}
  alias Manifold.Repo

  def discover(connection, opts \\ []) do
    with {:ok, credentials} <- CalendarConnections.credentials(connection, opts),
         {:ok, %{identity: principal, collections: collections}} <-
           Client.discover(credentials, :calendars, Keyword.put(opts, :include_identity, true)) do
      {:ok,
       Enum.map(collections, fn collection ->
         %{
           id: collection.href,
           name: collection.name,
           capabilities: %{
             "write" => collection.writable,
             "create" => collection.can_create,
             "update" => collection.can_update,
             "delete" => collection.can_delete
           },
           metadata: %{"principal" => principal, "sync_token" => collection.sync_token}
         }
       end)}
    end
  end

  def fetch_changes(binding, checkpoint, opts \\ []) do
    with {:ok, credentials} <- CalendarConnections.credentials(connection(binding, opts), opts),
         {:ok, href} <- URL.validate(binding.remote_calendar_id),
         {:ok, batch} <-
           Client.sync_collection(
             %{href: href, sync_token: checkpoint["sync_token"]},
             credentials,
             opts
           ) do
      entries =
        Enum.map(batch.entries, fn entry ->
          %{
            id: entry.href,
            href: entry.href,
            raw: entry.content,
            etag: entry.etag,
            presence: :present,
            metadata: %{}
          }
        end)

      deleted =
        Enum.map(
          batch.deleted,
          &%{id: &1, href: &1, raw: nil, etag: nil, presence: :deleted, metadata: %{}}
        )

      {:ok,
       %{
         complete: true,
         mode: batch.mode,
         resources: entries ++ deleted,
         checkpoint: %{"sync_token" => batch.sync_token}
       }}
    end
  end

  def fetch_resource(resource, opts \\ []) do
    binding =
      Keyword.get_lazy(opts, :binding, fn -> Repo.get!(CalendarBinding, resource.binding_id) end)

    with {:ok, credentials} <- CalendarConnections.credentials(connection(binding, opts), opts),
         {:ok, href} <- destination(binding, resource),
         {:ok, result} <- Client.get_resource(href, credentials, opts) do
      case result do
        :missing ->
          {:ok,
           %{id: resource.remote_resource_id, href: href, raw: nil, etag: nil, presence: :deleted}}

        %{content: raw, etag: etag} ->
          {:ok,
           %{
             id: resource.remote_resource_id,
             href: href,
             raw: raw,
             etag: etag,
             presence: :present
           }}
      end
    end
  end

  def decode(%{presence: :deleted}, _opts), do: {:ok, []}

  def decode(snapshot, _opts) do
    with {:ok, events} <- ICalendar.parse(snapshot.raw) do
      components =
        Enum.map(events, fn event ->
          projection =
            Map.new(CalendarSyncState.fields(), fn field ->
              value = Map.get(event, String.to_existing_atom(field))

              value =
                if field in [
                     "summary",
                     "description",
                     "location",
                     "ends_at",
                     "timezone",
                     "recurrence_timezone"
                   ] and value == "",
                   do: nil,
                   else: value

              {field, value}
            end)

          projection =
            projection
            |> Map.put("deleted", Map.get(event, :deleted, false))
            |> Map.put("recurrence_dates", Map.get(event, :recurrence_dates, []))
            |> Map.put("time_kind", time_kind(event))
            |> Map.put("reminders", Map.get(event, :reminders, []))

          %{
            key: event.uid <> <<31>> <> event.recurrence_id,
            projection: projection,
            fields:
              if(Map.get(event, :unsupported_alarms, false),
                do: List.delete(Map.keys(projection), "reminders"),
                else: Map.keys(projection)
              ),
            metadata: %{
              uid: event.uid,
              series_key: snapshot.id <> <<31>> <> event.uid,
              capability_limits:
                if(Map.get(event, :unsupported_alarms, false),
                  do: ["unsupported_alarms"],
                  else: []
                )
            }
          }
        end)

      {:ok, components}
    end
  end

  def encode(resource, components, _opts) do
    # Retain the complete server representation, including unrelated components,
    # timezone definitions, alarms and unknown provider properties.
    Enum.reduce_while(components, {:ok, Map.get(resource, :base_raw)}, fn component, {:ok, raw} ->
      uid = component.event.uid
      rid = component.projection["recurrence_id"] || ""

      result =
        if component.projection["deleted"] do
          Document.delete_event(raw, uid, if(rid == "", do: :series, else: rid))
        else
          Document.event(raw, component.projection, uid, rid)
        end

      case result do
        {:ok, :empty} -> {:cont, {:ok, nil}}
        {:ok, updated} -> {:cont, {:ok, updated}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  def destination(binding, resource) do
    case Map.get(resource, :href) do
      href when is_binary(href) and href != "" ->
        URL.validate(href)

      _ ->
        with {:ok, collection} <- URL.validate(binding.remote_calendar_id) do
          id = resource.remote_resource_id

          if is_binary(id) and Regex.match?(~r/\A[a-zA-Z0-9_-]+\z/, id),
            do: URL.resolve(String.trim_trailing(collection, "/") <> "/", id <> ".ics"),
            else: {:error, :invalid_resource_identity}
        end
    end
  end

  def validate_delete(%{base_raw: nil}, _components, _opts), do: :ok

  def validate_delete(resource, _components, _opts) do
    case Document.delete_calendar(resource.base_raw) do
      {:ok, :empty} -> :ok
      {:error, _} = error -> error
    end
  end

  defp condition(%{"if_match" => etag}), do: {:ok, etag}
  defp condition(%{"if_none_match" => "*"}), do: {:ok, :create}
  defp condition(_), do: {:error, :missing_precondition}

  def execute(attempt, connection, opts \\ []) do
    with {:ok, credentials} <- CalendarConnections.credentials(connection, opts) do
      result =
        if attempt.operation == "delete" do
          Client.delete_resource(
            attempt.destination,
            credentials,
            attempt.precondition["if_match"],
            opts
          )
        else
          case condition(attempt.precondition) do
            {:ok, condition} ->
              Client.put_resource(
                attempt.destination,
                credentials,
                :calendars,
                attempt.payload,
                condition,
                opts
              )

            {:error, _} = error ->
              error
          end
        end

      case result do
        {:ok, :deleted} -> {:ok, %{etag: nil, raw: nil}}
        {:ok, result} -> {:ok, Map.put(result, :raw, attempt.payload)}
        {:error, :outcome_unknown} -> {:error, :unknown}
        error -> error
      end
    end
  end

  defp connection(binding, opts) do
    Keyword.get_lazy(opts, :connection, fn ->
      Repo.get!(CalendarConnection, binding.connection_id)
    end)
  end

  defp time_kind(%{all_day: true}), do: "date"

  defp time_kind(%{starts_at: start, timezone: timezone}) do
    cond do
      String.ends_with?(start, "Z") -> "utc"
      timezone in [nil, ""] -> "floating"
      true -> "tzid"
    end
  end
end
