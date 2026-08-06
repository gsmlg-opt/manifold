defmodule Manifold.Connectors.EAS.Client do
  @moduledoc false

  @behaviour Manifold.Connectors.EAS.Transport

  alias Manifold.Connectors.EAS.WBXML
  alias Manifold.Connectors.Provider.Error

  defstruct [
    :settings,
    :policy_key,
    :req_options
  ]

  @connect_timeout 15_000
  @receive_timeout 60_000
  @inbox_type "2"

  @impl true
  def connect(settings) when is_map(settings) do
    connect_start = System.monotonic_time()
    base_meta = base_meta(settings)
    Process.put({__MODULE__, :emit_activity}, Map.get(settings, :emit_activity, true))

    with :ok <- validate_settings(settings) do
      conn = %__MODULE__{
        settings: settings,
        policy_key: Map.get(settings, :policy_key) || "0",
        req_options: Map.get(settings, :req_options, [])
      }

      auth_start = System.monotonic_time()

      case options_request(conn) do
        {:ok, conn} ->
          emit([:manifold, :connectors, :eas, :connect, :stop], connect_start, base_meta, :ok)
          emit([:manifold, :connectors, :eas, :auth, :stop], auth_start, auth_meta(settings), :ok)
          {:ok, conn}

        {:error, %Error{} = error} ->
          emit([:manifold, :connectors, :eas, :connect, :stop], connect_start, base_meta, error)

          emit(
            [:manifold, :connectors, :eas, :auth, :stop],
            auth_start,
            auth_meta(settings),
            error
          )

          {:error, error}
      end
    else
      {:error, %Error{} = error} ->
        emit([:manifold, :connectors, :eas, :connect, :stop], connect_start, base_meta, error)
        {:error, error}
    end
  end

  @impl true
  def provision(%__MODULE__{} = conn) do
    start = System.monotonic_time()

    body =
      WBXML.encode(
        {14, "Provision",
         [
           {14, "Policies",
            [
              {14, "Policy",
               [
                 {14, "PolicyType", ["MS-EAS-Provisioning-WBXML"]}
               ]}
            ]}
         ]}
      )

    case request(conn, "Provision", body) do
      {:ok, conn, root} ->
        status = WBXML.text(WBXML.find(root, "Status")) || "1"

        if status in ["1", "2"] do
          policy_key = WBXML.text(WBXML.find(root, "PolicyKey")) || conn.policy_key || "0"
          conn = %{conn | policy_key: policy_key}

          ack =
            WBXML.encode(
              {14, "Provision",
               [
                 {14, "Policies",
                  [
                    {14, "Policy",
                     [
                       {14, "PolicyType", ["MS-EAS-Provisioning-WBXML"]},
                       {14, "PolicyKey", [policy_key]},
                       {14, "Status", ["1"]}
                     ]}
                  ]}
               ]}
            )

          case request(conn, "Provision", ack) do
            {:ok, conn, ack_root} ->
              final_key = WBXML.text(WBXML.find(ack_root, "PolicyKey")) || policy_key
              conn = %{conn | policy_key: final_key}

              emit(
                [:manifold, :connectors, :eas, :provision, :stop],
                start,
                Map.put(base_meta(conn.settings), :policy_key, final_key),
                :ok
              )

              {:ok, conn, %{policy_key: final_key}}

            {:error, %Error{} = error} ->
              emit(
                [:manifold, :connectors, :eas, :provision, :stop],
                start,
                base_meta(conn.settings),
                error
              )

              {:error, error}
          end
        else
          error = %Error{
            class: :permanent,
            code: :provision_failed,
            message: "EAS provision failed with status #{status}"
          }

          emit(
            [:manifold, :connectors, :eas, :provision, :stop],
            start,
            base_meta(conn.settings),
            error
          )

          {:error, error}
        end

      {:error, %Error{code: :provision_required} = _error} ->
        # Retry once after empty policy key challenge.
        provision(%{conn | policy_key: "0"})

      {:error, %Error{} = error} ->
        emit(
          [:manifold, :connectors, :eas, :provision, :stop],
          start,
          base_meta(conn.settings),
          error
        )

        {:error, error}
    end
  end

  @impl true
  def folder_sync(%__MODULE__{} = conn, sync_key) when is_binary(sync_key) do
    body = WBXML.encode({5, "FolderSync", [{5, "SyncKey", [sync_key]}]})

    case request(conn, "FolderSync", body) do
      {:ok, conn, root} ->
        status = WBXML.text(WBXML.find(root, "Status")) || "1"

        if status == "1" do
          new_key = WBXML.text(WBXML.find(root, "SyncKey")) || sync_key

          folders =
            root
            |> WBXML.find_all("Add")
            |> Enum.map(&folder_from_add/1)
            |> Enum.reject(&is_nil/1)

          {:ok, conn, %{sync_key: new_key, folders: folders}}
        else
          {:error,
           %Error{
             class: :temporary,
             code: :folder_sync_failed,
             message: "EAS FolderSync failed with status #{status}"
           }}
        end

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  @impl true
  def sync(%__MODULE__{} = conn, opts) when is_map(opts) do
    collection_id = Map.fetch!(opts, :collection_id)
    sync_key = Map.get(opts, :sync_key, "0")
    window_size = Map.get(opts, :window_size, 25)

    collection_children =
      [
        {0, "SyncKey", [to_string(sync_key)]},
        {0, "CollectionId", [collection_id]},
        {0, "GetChanges", :empty},
        {0, "WindowSize", [Integer.to_string(window_size)]}
      ]

    collection_children =
      if sync_key == "0" do
        collection_children ++
          [
            {0, "Options",
             [
               {0, "FilterType", ["0"]},
               {17, "BodyPreference", [{17, "Type", ["4"]}]}
             ]}
          ]
      else
        collection_children
      end

    body =
      WBXML.encode(
        {0, "Sync",
         [
           {0, "Collections",
            [
              {0, "Collection", collection_children}
            ]}
         ]}
      )

    case request(conn, "Sync", body) do
      {:ok, conn, root} ->
        status = WBXML.text(WBXML.find(root, "Status")) || "1"

        cond do
          status == "1" ->
            new_key = WBXML.text(WBXML.child(WBXML.find(root, "Collection") || root, "SyncKey"))
            new_key = new_key || WBXML.text(WBXML.find(root, "SyncKey")) || sync_key

            adds =
              root
              |> WBXML.find_all("Add")
              |> Enum.map(&sync_item_from_node/1)
              |> Enum.reject(&is_nil/1)

            changes =
              root
              |> WBXML.find_all("Change")
              |> Enum.map(&sync_item_from_node/1)
              |> Enum.reject(&is_nil/1)

            deletes =
              root
              |> WBXML.find_all("Delete")
              |> Enum.map(&WBXML.text(WBXML.child(&1, "ServerId")))
              |> Enum.reject(&is_nil/1)

            more? = match?({_, "MoreAvailable", _}, WBXML.find(root, "MoreAvailable"))

            {:ok, conn,
             %{
               sync_key: new_key,
               adds: adds,
               changes: changes,
               deletes: deletes,
               more_available?: more?
             }}

          status == "3" ->
            # Invalid sync key — caller should reset.
            {:error,
             %Error{
               class: :permanent,
               code: :cursor_reset,
               message: "EAS SyncKey invalid; reset required"
             }}

          true ->
            {:error,
             %Error{
               class: :temporary,
               code: :sync_failed,
               message: "EAS Sync failed with status #{status}"
             }}
        end

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  @impl true
  def change_read(%__MODULE__{} = conn, opts) when is_map(opts) do
    collection_id = Map.fetch!(opts, :collection_id)
    server_id = Map.fetch!(opts, :server_id)
    read? = Map.fetch!(opts, :read?)
    sync_key = Map.fetch!(opts, :sync_key)
    read_value = if(read?, do: "1", else: "0")

    body =
      WBXML.encode(
        {0, "Sync",
         [
           {0, "Collections",
            [
              {0, "Collection",
               [
                 {0, "SyncKey", [to_string(sync_key)]},
                 {0, "CollectionId", [collection_id]},
                 {0, "Commands",
                  [
                    {0, "Change",
                     [
                       {0, "ServerId", [server_id]},
                       {0, "ApplicationData", [{2, "Read", [read_value]}]}
                     ]}
                  ]}
               ]}
            ]}
         ]}
      )

    case request(conn, "Sync", body) do
      {:ok, conn, root} ->
        status = WBXML.text(WBXML.find(root, "Status")) || "1"

        if status == "1" do
          new_key = WBXML.text(WBXML.child(WBXML.find(root, "Collection") || root, "SyncKey"))
          new_key = new_key || WBXML.text(WBXML.find(root, "SyncKey")) || sync_key
          {:ok, conn, %{sync_key: new_key}}
        else
          {:error,
           %Error{
             class: :temporary,
             code: :change_failed,
             message: "EAS Change failed with status #{status}"
           }}
        end

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  @impl true
  def fetch_mime(%__MODULE__{} = conn, collection_id, server_id)
      when is_binary(collection_id) and is_binary(server_id) do
    body =
      WBXML.encode(
        {20, "ItemOperations",
         [
           {20, "Fetch",
            [
              {20, "Store", ["Mailbox"]},
              {0, "CollectionId", [collection_id]},
              {0, "ServerId", [server_id]},
              {20, "Options",
               [
                 {17, "BodyPreference",
                  [
                    {17, "Type", ["4"]},
                    {17, "AllOrNone", ["1"]}
                  ]}
               ]}
            ]}
         ]}
      )

    case request(conn, "ItemOperations", body) do
      {:ok, _conn, root} ->
        status = WBXML.text(WBXML.find(root, "Status")) || "1"

        if status == "1" do
          data =
            case WBXML.find(root, "Data") do
              nil -> nil
              node -> WBXML.text(node)
            end

          cond do
            is_binary(data) and data != "" ->
              decode_mime_payload(data)

            true ->
              {:error,
               %Error{
                 class: :permanent,
                 code: :message_not_found,
                 message: "EAS ItemOperations returned empty MIME"
               }}
          end
        else
          {:error,
           %Error{
             class: :temporary,
             code: :fetch_failed,
             message: "EAS ItemOperations failed with status #{status}"
           }}
        end

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  @impl true
  def close(%__MODULE__{}), do: :ok

  @doc false
  def inbox_collection_id(folders) when is_list(folders) do
    Enum.find_value(folders, fn
      %{type: type, server_id: id} when type in [@inbox_type, 2, "2"] and is_binary(id) ->
        id

      %{display_name: name, server_id: id} when is_binary(id) ->
        if is_binary(name) and String.downcase(name) == "inbox", do: id, else: nil

      _ ->
        nil
    end)
  end

  # OPTIONS is best-effort: many on-prem servers answer poorly. Auth is validated
  # by subsequent Provision / FolderSync.
  defp options_request(conn) do
    url = base_url(conn.settings)

    headers = [
      {"authorization", basic_auth(conn.settings)},
      {"ms-asprotocolversion", conn.settings.protocol_version},
      {"user-agent", "Manifold"}
    ]

    case http_request(conn, method: :options, url: url, headers: headers, body: "") do
      {:ok, %{status: 401}} ->
        {:error,
         %Error{class: :reconnect, code: :auth_failed, message: "EAS authentication failed"}}

      {:ok, _response} ->
        {:ok, conn}

      {:error, %Error{code: :auth_failed} = error} ->
        {:error, error}

      {:error, _error} ->
        {:ok, conn}
    end
  end

  defp request(conn, cmd, body) when is_binary(cmd) and is_binary(body) do
    url = command_url(conn.settings, cmd)

    headers = [
      {"authorization", basic_auth(conn.settings)},
      {"content-type", "application/vnd.ms-sync.wbxml"},
      {"ms-asprotocolversion", conn.settings.protocol_version},
      {"x-ms-policykey", conn.policy_key || "0"},
      {"user-agent", "Manifold"}
    ]

    case http_request(conn, method: :post, url: url, headers: headers, body: body) do
      {:ok, %{status: 449}} ->
        {:error,
         %Error{
           class: :temporary,
           code: :provision_required,
           message: "EAS provision required"
         }}

      {:ok, %{status: 401}} ->
        {:error,
         %Error{class: :reconnect, code: :auth_failed, message: "EAS authentication failed"}}

      {:ok, %{status: status, body: resp_body}} when status in 200..299 ->
        if is_binary(resp_body) and byte_size(resp_body) > 0 do
          case WBXML.decode(resp_body) do
            {:ok, root} ->
              {:ok, conn, root}

            {:error, _} ->
              {:error,
               %Error{
                 class: :temporary,
                 code: :invalid_response,
                 message: "EAS returned invalid WBXML"
               }}
          end
        else
          # Empty success body (rare).
          {:ok, conn, {0, "Sync", []}}
        end

      {:ok, %{status: status}} ->
        {:error,
         %Error{
           class: :temporary,
           code: :http_error,
           message: "EAS #{cmd} failed with HTTP #{status}"
         }}

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp http_request(conn, opts) do
    options =
      [
        receive_timeout: @receive_timeout,
        connect_options: [timeout: @connect_timeout]
      ]
      |> Keyword.merge(conn.req_options || [])
      |> Keyword.merge(opts)

    case Req.request(options) do
      {:ok, %Req.Response{} = response} ->
        {:ok, %{status: response.status, body: response.body, headers: response.headers}}

      {:error, reason} ->
        {:error,
         %Error{
           class: :temporary,
           code: :connect_failed,
           message: "EAS request failed: #{Exception.message(reason)}"
         }}
    end
  rescue
    e in [ArgumentError, ErlangError, RuntimeError] ->
      {:error,
       %Error{
         class: :temporary,
         code: :connect_failed,
         message: "EAS request failed: #{Exception.message(e)}"
       }}
  end

  defp folder_from_add(add) do
    server_id =
      WBXML.text(WBXML.child(add, "ServerId")) || WBXML.text(WBXML.find(add, "ServerId"))

    if is_binary(server_id) do
      %{
        server_id: server_id,
        display_name: WBXML.text(WBXML.find(add, "DisplayName")),
        type: WBXML.text(WBXML.find(add, "Type")),
        parent_id: WBXML.text(WBXML.find(add, "ParentId"))
      }
    else
      nil
    end
  end

  defp sync_item_from_node(node) do
    server_id =
      WBXML.text(WBXML.child(node, "ServerId")) || WBXML.text(WBXML.find(node, "ServerId"))

    if is_binary(server_id) do
      %{
        server_id: server_id,
        read?: read_flag?(node),
        received_at: date_received(node)
      }
    else
      nil
    end
  end

  defp read_flag?(node) do
    case WBXML.find(node, "Read") do
      nil -> false
      read_node -> WBXML.text(read_node) in ["1", "true"]
    end
  end

  defp date_received(node) do
    case WBXML.text(WBXML.find(node, "DateReceived")) do
      value when is_binary(value) and value != "" ->
        case DateTime.from_iso8601(value) do
          {:ok, datetime, _offset} ->
            {us, _} = datetime.microsecond
            %{datetime | microsecond: {us, 6}}

          {:error, _} ->
            nil
        end

      _ ->
        nil
    end
  end

  defp decode_mime_payload(data) do
    # ItemOperations may return base64 MIME.
    case Base.decode64(String.replace(data, ~r/\s+/, "")) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> {:ok, data}
    end
  end

  defp base_url(settings) do
    path = settings.path |> String.trim() |> ensure_leading_slash()
    "https://#{settings.host}:#{settings.port}#{path}"
  end

  defp command_url(settings, cmd) do
    base = base_url(settings)
    user = URI.encode_www_form(settings.username)
    device_id = URI.encode_www_form(settings.device_id)
    device_type = URI.encode_www_form(settings.device_type)

    "#{base}?Cmd=#{cmd}&User=#{user}&DeviceId=#{device_id}&DeviceType=#{device_type}"
  end

  defp ensure_leading_slash(<<"/", _::binary>> = path), do: path
  defp ensure_leading_slash(path), do: "/" <> path

  defp basic_auth(settings) do
    token = Base.encode64("#{settings.username}:#{settings.password}")
    "Basic #{token}"
  end

  defp validate_settings(settings) do
    required = [
      :host,
      :port,
      :path,
      :username,
      :password,
      :device_id,
      :device_type,
      :protocol_version
    ]

    missing =
      Enum.find(required, fn key ->
        value = Map.get(settings, key)
        is_nil(value) or value == ""
      end)

    if missing do
      {:error,
       %Error{
         class: :permanent,
         code: :invalid_eas_settings,
         message: "EAS #{missing} is required"
       }}
    else
      :ok
    end
  end

  defp base_meta(settings) do
    %{
      host: Map.get(settings, :host),
      port: Map.get(settings, :port),
      provider: "eas"
    }
    |> maybe_put(:account_id, Map.get(settings, :account_id))
  end

  defp auth_meta(settings) do
    settings
    |> base_meta()
    |> maybe_put(:username, Map.get(settings, :username))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp emit(event, start, meta, :ok) do
    if Process.get({__MODULE__, :emit_activity}, true) != false do
      :telemetry.execute(event, %{duration_ms: now_ms(start)}, Map.put(meta, :result, :ok))
    end
  end

  defp emit(event, start, meta, %Error{} = error) do
    if Process.get({__MODULE__, :emit_activity}, true) != false do
      :telemetry.execute(
        event,
        %{duration_ms: now_ms(start)},
        meta
        |> Map.put(:result, :error)
        |> Map.put(:error_code, error.code)
        |> Map.put(:error_message, error.message)
      )
    end
  end

  defp now_ms(start) do
    System.convert_time_unit(System.monotonic_time() - start, :native, :millisecond)
  end
end
