defmodule Manifold.Connectors.EAS.Client do
  @moduledoc false

  @behaviour Manifold.Connectors.EAS.Transport

  alias Manifold.Connectors.EAS.WBXML
  alias Manifold.Connectors.Provider.Error

  defstruct [
    :settings,
    :policy_key,
    :req_options,
    # Sticky MS-ASHTTP query encoding after the first success on this connection.
    :query_mode,
    cookies: []
  ]

  @connect_timeout 15_000
  @receive_timeout 60_000
  @inbox_type "2"
  # Phone-like identity — QQ Exmail and similar gateways fingerprint clients.
  @user_agent "Apple-iPhone15C1/2202.75"
  # Prefer 14.0 ahead of 14.1 — QQ Exmail documents 14.0 only, and several
  # SaaS gateways fingerprint/reject 14.1 DeviceInformation-in-Provision flows.
  @protocol_versions ["14.0", "14.1", "16.0", "16.1", "12.1", "12.0"]
  # MS-ASHTTP command codes for base64-encoded query values.
  @command_codes %{
    "Sync" => 0,
    "FolderSync" => 9,
    "Settings" => 17,
    "ItemOperations" => 19,
    "Provision" => 20
  }

  @impl true
  def connect(settings) when is_map(settings) do
    connect_start = System.monotonic_time()
    base_meta = base_meta(settings)
    Process.put({__MODULE__, :emit_activity}, Map.get(settings, :emit_activity, true))

    with :ok <- validate_settings(settings) do
      conn = %__MODULE__{
        settings: settings,
        policy_key: Map.get(settings, :policy_key) || "0",
        req_options: Map.get(settings, :req_options, []),
        query_mode: Map.get(settings, :force_query_mode),
        cookies: []
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
    body = WBXML.encode(provision_request_doc(conn))

    case request(conn, "Provision", body) do
      {:ok, conn, root} ->
        outer_status = WBXML.text(WBXML.child(root, "Status")) || "1"

        if outer_status == "1" do
          policy = WBXML.find(root, "Policy")
          policy_status = policy_status(policy)
          policy_key = WBXML.text(WBXML.find(root, "PolicyKey")) || conn.policy_key || "0"

          cond do
            # Policy not defined / absent — continue without acknowledge.
            policy_status in [nil, "2"] ->
              final_key =
                if policy_key in [nil, ""], do: "0", else: to_string(policy_key)

              conn = %{conn | policy_key: final_key}

              with {:ok, conn} <- maybe_settings_device_information(conn) do
                emit_provision_ok(conn, start, final_key)
                {:ok, conn, %{policy_key: final_key}}
              end

            policy_status == "1" ->
              conn = %{conn | policy_key: to_string(policy_key)}
              ack = WBXML.encode(provision_ack_doc(policy_key))

              case request(conn, "Provision", ack) do
                {:ok, conn, ack_root} ->
                  final_key =
                    WBXML.text(WBXML.find(ack_root, "PolicyKey")) || to_string(policy_key)

                  conn = %{conn | policy_key: final_key}

                  with {:ok, conn} <- maybe_settings_device_information(conn) do
                    emit_provision_ok(conn, start, final_key)
                    {:ok, conn, %{policy_key: final_key}}
                  end

                {:error, %Error{} = error} ->
                  emit_provision_error(conn, start, error)
                  {:error, error}
              end

            true ->
              error = %Error{
                class: :permanent,
                code: :provision_failed,
                message: "EAS provision policy status #{policy_status || "unknown"}"
              }

              emit_provision_error(conn, start, error)
              {:error, error}
          end
        else
          error = %Error{
            class: :permanent,
            code: :provision_failed,
            message: "EAS provision failed with status #{outer_status}"
          }

          emit_provision_error(conn, start, error)
          {:error, error}
        end

      {:error, %Error{code: :provision_required} = _error} ->
        # Retry once after empty policy key challenge.
        provision(%{conn | policy_key: "0"})

      {:error, %Error{} = error} ->
        emit_provision_error(conn, start, error)
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
  # by subsequent Provision / FolderSync. When present, MS-ASProtocolVersions is
  # used to pick a mutually supported protocol version.
  defp options_request(conn) do
    preferred = preferred_protocol_version(conn.settings)
    conn = %{conn | settings: Map.put(conn.settings, :protocol_version, preferred)}
    url = base_url(conn.settings)

    headers =
      [
        {"authorization", basic_auth(conn.settings)},
        {"ms-asprotocolversion", preferred},
        {"accept", "*/*"},
        {"accept-language", "en-us"}
      ]
      |> maybe_put_cookie(conn)

    case http_request(conn,
           method: :options,
           url: url,
           headers: headers,
           body: "",
           user_agent: @user_agent
         ) do
      {:ok, %{status: 401}} ->
        {:error,
         %Error{class: :reconnect, code: :auth_failed, message: "EAS authentication failed"}}

      {:ok, %{headers: headers} = response} ->
        version = pick_protocol_version(headers, preferred)

        conn =
          conn
          |> store_cookies(response)
          |> then(fn c -> %{c | settings: Map.put(c.settings, :protocol_version, version)} end)

        {:ok, conn}

      {:error, %Error{code: :connect_failed} = error} ->
        # DNS / TLS / connect failures must surface — do not treat as "OPTIONS optional".
        {:error, error}

      {:error, _error} ->
        # Other OPTIONS failures (timeouts, odd gateways) remain best-effort.
        {:ok, conn}
    end
  end

  defp request(conn, cmd, body) when is_binary(cmd) and is_binary(body) do
    versions = protocol_fallback_versions(conn.settings.protocol_version)

    modes =
      case conn.query_mode do
        mode when mode in [:plain, :base64] -> [mode]
        _ -> query_mode_order(conn.settings)
      end

    request(conn, cmd, body, versions, modes)
  end

  defp request(conn, cmd, body, versions, [query_mode | rest_modes] = modes)
       when is_list(versions) and query_mode in [:plain, :base64] do
    [version | remaining] = versions
    conn = %{conn | settings: Map.put(conn.settings, :protocol_version, version)}
    url = command_url(conn.settings, cmd, query_mode, conn.policy_key)

    headers =
      [
        {"authorization", basic_auth(conn.settings)},
        {"content-type", "application/vnd.ms-sync.wbxml"},
        {"ms-asprotocolversion", version},
        {"x-ms-policykey", conn.policy_key || "0"},
        {"accept", "*/*"},
        {"accept-language", "en-us"}
      ]
      |> maybe_put_cookie(conn)

    case http_request(conn,
           method: :post,
           url: url,
           headers: headers,
           body: body,
           user_agent: @user_agent
         ) do
      {:ok, %{status: 449} = response} ->
        _ = store_cookies(conn, response)

        {:error,
         %Error{
           class: :temporary,
           code: :provision_required,
           message: "EAS provision required"
         }}

      {:ok, %{status: 401}} ->
        {:error,
         %Error{class: :reconnect, code: :auth_failed, message: "EAS authentication failed"}}

      {:ok, %{status: status, body: resp_body} = response} when status in 200..299 ->
        conn =
          conn
          |> store_cookies(response)
          |> then(fn c -> %{c | query_mode: query_mode} end)

        if is_binary(resp_body) and byte_size(resp_body) > 0 do
          case WBXML.decode(resp_body) do
            {:ok, root} ->
              {:ok, conn, root}

            {:error, _} ->
              {:error, invalid_wbxml_error(cmd, resp_body)}
          end
        else
          # Empty success body (rare).
          {:ok, conn, {0, "Sync", []}}
        end

      {:ok, %{status: 400, body: resp_body}} ->
        cond do
          remaining != [] and not gateway_html_400?(resp_body) ->
            # Unsupported protocol versions commonly surface as HTTP 400 (non-HTML).
            request(conn, cmd, body, remaining, modes)

          gateway_html_400?(resp_body) and rest_modes != [] ->
            # QQ / nginx gateways often require the other MS-ASHTTP query encoding.
            request(conn, cmd, body, protocol_fallback_versions(version), rest_modes)

          remaining != [] ->
            request(conn, cmd, body, remaining, modes)

          rest_modes != [] ->
            request(
              conn,
              cmd,
              body,
              protocol_fallback_versions(conn.settings.protocol_version),
              rest_modes
            )

          true ->
            {:error, http_error(cmd, 400, resp_body, conn.settings.host)}
        end

      {:ok, %{status: status, body: resp_body}} ->
        {:error, http_error(cmd, status, resp_body, conn.settings.host)}

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp http_request(conn, opts) do
    options =
      [
        receive_timeout: @receive_timeout,
        connect_options: [timeout: @connect_timeout, protocols: [:http1]],
        decode_body: true,
        compressed: false,
        # Use Req's user_agent option so we do not end up with "Apple…, req/x.y".
        user_agent: @user_agent
      ]
      |> Keyword.merge(conn.req_options || [])
      |> Keyword.merge(opts)

    case Req.request(options) do
      {:ok, %Req.Response{} = response} ->
        {:ok, %{status: response.status, body: response.body, headers: response.headers}}

      {:error, reason} ->
        {:error, connect_failed_error(reason)}
    end
  rescue
    e in [ArgumentError, ErlangError, RuntimeError] ->
      {:error, connect_failed_error(e)}
  end

  @doc false
  def format_transport_reason(reason) do
    message =
      if Exception.exception?(reason), do: Exception.message(reason), else: inspect(reason)

    cond do
      transport_reason(reason) == :nxdomain or message == "non-existing domain" ->
        "DNS lookup failed for Host (hostname not found). Check Host spelling — this is not the optional Domain/auth field"

      match?(%{reason: _}, reason) ->
        "connection to Host failed (#{message})"

      true ->
        message
    end
  end

  defp connect_failed_error(reason) do
    %Error{
      class: :temporary,
      code: :connect_failed,
      message: "EAS request failed: #{format_transport_reason(reason)}"
    }
  end

  defp transport_reason(%{reason: reason}), do: reason
  defp transport_reason(_), do: nil

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

  defp invalid_wbxml_error(cmd, body) when is_binary(body) do
    trimmed = String.trim_leading(body)
    snippet = body_snippet(body)

    message =
      cond do
        String.starts_with?(trimmed, "<") or String.starts_with?(trimmed, "<!") ->
          "EAS #{cmd} returned HTML/XML instead of WBXML (check host/path/auth; use an app password if required)"

        match?(<<0x03, _::binary>>, body) ->
          "EAS #{cmd} returned WBXML that could not be parsed"

        true ->
          "EAS #{cmd} returned a non-WBXML body (#{snippet})"
      end

    %Error{class: :temporary, code: :invalid_response, message: message}
  end

  defp http_error(cmd, status, body, host \\ nil) do
    detail =
      cond do
        gateway_html_400?(body) and status == 400 and qq_exmail_host?(host) ->
          " — QQ Exmail ActiveSync rejected this non-mobile client (HTML 400). Their EAS gateway allowlists phone Mail apps; server-side importers should use IMAP (imap.exmail.qq.com:993) instead"

        gateway_html_400?(body) and status == 400 ->
          " — gateway rejected the ActiveSync request (HTML 400). Tried protocol/query fallbacks. Confirm Exchange ActiveSync is enabled for the mailbox and use an app/authorization password"

        is_binary(body) and String.trim(body) != "" ->
          " - #{body_snippet(body)}"

        true ->
          ""
      end

    %Error{
      class: :temporary,
      code: :http_error,
      message: "EAS #{cmd} failed with HTTP #{status}#{detail}"
    }
  end

  defp gateway_html_400?(body) when is_binary(body) do
    trimmed = String.trim_leading(body)
    String.starts_with?(trimmed, "<") and String.contains?(trimmed, "400")
  end

  defp gateway_html_400?(_), do: false

  defp body_snippet(body) when is_binary(body) and body != "" do
    body
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.slice(0, 120)
  end

  defp body_snippet(_), do: ""

  defp base_url(settings) do
    path =
      settings.path
      |> to_string()
      |> String.trim()
      |> ensure_leading_slash()
      |> String.trim_trailing("/")

    host_port =
      case settings.port do
        port when port in [443, "443"] -> to_string(settings.host)
        port -> "#{settings.host}:#{port}"
      end

    "https://#{host_port}#{path}"
  end

  @doc false
  def command_url(settings, cmd, query_mode \\ :plain, policy_key \\ "0")

  def command_url(settings, cmd, :plain, _policy_key)
      when is_map(settings) and is_binary(cmd) do
    base = base_url(settings)
    user = encode_eas_query_value(query_user(settings))
    device_id = encode_eas_query_value(to_string(settings.device_id))
    device_type = encode_eas_query_value(to_string(settings.device_type))

    # MS-ASHTTP documented order is Cmd, User, DeviceId, DeviceType. Leave `@`
    # in User unencoded — some gateways mishandle `%40`.
    "#{base}?Cmd=#{cmd}&User=#{user}&DeviceId=#{device_id}&DeviceType=#{device_type}"
  end

  def command_url(settings, cmd, :base64, policy_key)
      when is_map(settings) and is_binary(cmd) do
    base = base_url(settings)
    encoded = base64_query_value(settings, cmd, policy_key)
    "#{base}?#{encoded}"
  end

  defp encode_eas_query_value(value) when is_binary(value) do
    URI.encode(value, &eas_query_char_allowed?/1)
  end

  # Keep `@` literal — Apple clients do; some gateways mishandle `%40`.
  defp eas_query_char_allowed?(c) when c in ?A..?Z, do: true
  defp eas_query_char_allowed?(c) when c in ?a..?z, do: true
  defp eas_query_char_allowed?(c) when c in ?0..?9, do: true
  defp eas_query_char_allowed?(c) when c in ~c"@.-_~", do: true
  defp eas_query_char_allowed?(_), do: false

  defp base64_query_value(settings, cmd, policy_key) do
    version_byte = protocol_version_byte(settings.protocol_version)
    command_code = Map.fetch!(@command_codes, cmd)
    locale = <<0x09, 0x04>>
    device_id = to_string(settings.device_id)
    device_type = to_string(settings.device_type)

    policy_bytes =
      case Integer.parse(to_string(policy_key || "0")) do
        {0, ""} ->
          <<0>>

        {int, ""} ->
          <<4, int::little-unsigned-32>>

        _ ->
          <<0>>
      end

    iodata = [
      <<version_byte, command_code>>,
      locale,
      <<byte_size(device_id)>>,
      device_id,
      policy_bytes,
      <<byte_size(device_type)>>,
      device_type
    ]

    iodata |> IO.iodata_to_binary() |> Base.encode64()
  end

  defp protocol_version_byte("16.1"), do: 161
  defp protocol_version_byte("16.0"), do: 160
  defp protocol_version_byte("14.1"), do: 141
  defp protocol_version_byte("14.0"), do: 140
  defp protocol_version_byte("12.1"), do: 121
  defp protocol_version_byte("12.0"), do: 120
  defp protocol_version_byte(_), do: 141

  defp ensure_leading_slash(<<"/", _::binary>> = path), do: path
  defp ensure_leading_slash(path), do: "/" <> path

  defp basic_auth(settings) do
    token = Base.encode64("#{auth_username(settings)}:#{settings.password}")
    "Basic #{token}"
  end

  defp provision_request_doc(conn) do
    policies =
      {14, "Policies",
       [
         {14, "Policy",
          [
            {14, "PolicyType", ["MS-EAS-Provisioning-WBXML"]}
          ]}
       ]}

    children =
      if device_information_in_provision?(conn.settings.protocol_version) do
        [device_information_node(conn), policies]
      else
        [policies]
      end

    {14, "Provision", children}
  end

  defp provision_ack_doc(policy_key) do
    {14, "Provision",
     [
       {14, "Policies",
        [
          {14, "Policy",
           [
             {14, "PolicyType", ["MS-EAS-Provisioning-WBXML"]},
             {14, "PolicyKey", [to_string(policy_key)]},
             {14, "Status", ["1"]}
           ]}
        ]}
     ]}
  end

  defp device_information_node(conn) do
    model = to_string(conn.settings.device_type || "iPhone")

    # Match Apple Mail field set closely — QQ gateways fingerprint these values.
    {18, "DeviceInformation",
     [
       {18, "Set",
        [
          {18, "Model", [model]},
          {18, "IMEI", ["0"]},
          {18, "FriendlyName", [model]},
          {18, "OS", ["iOS 18.0"]},
          {18, "OSLanguage", ["en"]},
          {18, "PhoneNumber", ["0"]},
          {18, "UserAgent", [@user_agent]},
          {18, "MobileOperator", ["Carrier"]}
        ]}
     ]}
  end

  # MS-ASPROV: DeviceInformation MUST be in initial Provision for 14.1/16.x,
  # and MUST NOT appear in Provision for 14.0/12.x (use Settings instead).
  defp device_information_in_provision?(version) when version in ["14.1", "16.0", "16.1"],
    do: true

  defp device_information_in_provision?(_), do: false

  defp maybe_settings_device_information(conn) do
    cond do
      device_information_in_provision?(conn.settings.protocol_version) ->
        {:ok, conn}

      Map.get(conn.settings, :skip_device_information) == true ->
        {:ok, conn}

      # QQ Exmail HTML-400s FolderSync after a Settings DeviceInformation round-trip
      # on some accounts; Provision alone is enough to proceed.
      qq_exmail_host?(Map.get(conn.settings, :host)) ->
        {:ok, conn}

      true ->
        body =
          WBXML.encode(
            {18, "Settings",
             [
               device_information_node(conn)
             ]}
          )

        case request(conn, "Settings", body) do
          {:ok, conn, _root} -> {:ok, conn}
          {:error, %Error{} = error} -> {:error, error}
        end
    end
  end

  defp policy_status(nil), do: nil

  defp policy_status(policy) do
    WBXML.text(WBXML.child(policy, "Status")) || WBXML.text(WBXML.find(policy, "Status"))
  end

  defp emit_provision_ok(conn, start, policy_key) do
    emit(
      [:manifold, :connectors, :eas, :provision, :stop],
      start,
      Map.put(base_meta(conn.settings), :policy_key, policy_key),
      :ok
    )
  end

  defp emit_provision_error(conn, start, error) do
    emit(
      [:manifold, :connectors, :eas, :provision, :stop],
      start,
      base_meta(conn.settings),
      error
    )
  end

  defp maybe_put_cookie(headers, %{cookies: cookies}) when is_list(cookies) and cookies != [] do
    value = Enum.map_join(cookies, "; ", fn {k, v} -> "#{k}=#{v}" end)
    headers ++ [{"cookie", value}]
  end

  defp maybe_put_cookie(headers, _), do: headers

  defp store_cookies(conn, %{headers: headers}) do
    new_cookies =
      headers
      |> header_values("set-cookie")
      |> Enum.map(&parse_set_cookie/1)
      |> Enum.reject(&is_nil/1)

    if new_cookies == [] do
      conn
    else
      merged =
        Enum.reduce(new_cookies, Map.new(conn.cookies || []), fn {k, v}, acc ->
          Map.put(acc, k, v)
        end)

      %{conn | cookies: Map.to_list(merged)}
    end
  end

  defp store_cookies(conn, _), do: conn

  defp parse_set_cookie(value) when is_binary(value) do
    case String.split(value, ";", parts: 2) do
      [pair | _] ->
        case String.split(pair, "=", parts: 2) do
          [name, val] ->
            name = String.trim(name)
            if name != "", do: {name, String.trim(val)}, else: nil

          _ ->
            nil
        end

      _ ->
        nil
    end
  end

  defp parse_set_cookie(_), do: nil

  @doc false
  def auth_username(settings) when is_map(settings) do
    username = settings |> Map.fetch!(:username) |> to_string() |> String.trim()
    domain = settings |> Map.get(:domain) |> blank_to_nil()

    cond do
      String.contains?(username, "\\") ->
        username

      is_binary(domain) ->
        domain <> "\\" <> username

      true ->
        username
    end
  end

  @doc false
  def query_user(settings) when is_map(settings) do
    case String.split(auth_username(settings), "\\", parts: 2) do
      [_domain, user] -> user
      [user] -> user
    end
  end

  @doc false
  def preferred_protocol_version(settings) when is_map(settings) do
    configured = Map.get(settings, :protocol_version) || "14.0"

    cond do
      Map.get(settings, :force_protocol_version) ->
        to_string(Map.get(settings, :force_protocol_version))

      qq_exmail_host?(Map.get(settings, :host)) and configured in ["16.1", "16.0", "14.1"] ->
        # QQ documents 14.0 only; 14.1+ Provision/FolderSync often HTML-400s.
        "14.0"

      true ->
        configured
    end
  end

  @doc false
  def query_mode_order(settings) when is_map(settings) do
    case Map.get(settings, :force_query_mode) do
      :base64 ->
        [:base64, :plain]

      :plain ->
        [:plain, :base64]

      _ ->
        # QQ Exmail's gateway is more reliable with MS-ASHTTP plain query
        # (Cmd&User&DeviceId&DeviceType) than base64-encoded query values.
        prefer_base64? = Map.get(settings, :prefer_base64_query) == true

        prefer_plain? =
          Map.get(settings, :prefer_base64_query) == false or
            qq_exmail_host?(Map.get(settings, :host))

        if prefer_base64? and not prefer_plain?, do: [:base64, :plain], else: [:plain, :base64]
    end
  end

  @doc false
  def qq_exmail_host?(host) when is_binary(host) do
    host = String.downcase(host)
    String.contains?(host, "exmail.qq.com") or host in ["ex.qq.com", "imap.exmail.qq.com"]
  end

  def qq_exmail_host?(_), do: false

  @doc false
  def gateway_html_400_error?(%Error{code: :http_error, message: message})
      when is_binary(message) do
    String.contains?(message, "gateway rejected")
  end

  def gateway_html_400_error?(_), do: false

  @doc false
  def pick_protocol_version(headers, preferred) when is_list(headers) or is_map(headers) do
    advertised = ms_as_protocol_versions(headers)
    preferred = preferred || "14.0"

    candidates =
      if advertised == [] do
        @protocol_versions
      else
        Enum.filter(@protocol_versions, &(&1 in advertised))
      end

    cond do
      preferred in candidates -> preferred
      candidates != [] -> hd(candidates)
      true -> preferred
    end
  end

  defp protocol_fallback_versions(current) do
    case Enum.find_index(@protocol_versions, &(&1 == current)) do
      nil -> [current | @protocol_versions] |> Enum.uniq()
      index -> Enum.drop(@protocol_versions, index)
    end
  end

  defp ms_as_protocol_versions(headers) do
    headers
    |> header_values("ms-asprotocolversions")
    |> Enum.flat_map(fn value ->
      value
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp header_values(headers, name) when is_map(headers) do
    key = Enum.find(Map.keys(headers), fn k -> String.downcase(to_string(k)) == name end)

    case key && Map.get(headers, key) do
      values when is_list(values) -> Enum.map(values, &to_string/1)
      value when is_binary(value) -> [value]
      _ -> []
    end
  end

  defp header_values(headers, name) when is_list(headers) do
    name = String.downcase(name)

    headers
    |> Enum.filter(fn {key, _} -> String.downcase(to_string(key)) == name end)
    |> Enum.flat_map(fn
      {_, values} when is_list(values) -> Enum.map(values, &to_string/1)
      {_, value} -> [to_string(value)]
    end)
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_), do: nil

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
