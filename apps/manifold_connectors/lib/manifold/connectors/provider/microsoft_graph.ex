defmodule Manifold.Connectors.Provider.MicrosoftGraph do
  @moduledoc """
  Microsoft Graph OAuth and mailbox synchronization adapter.
  """

  @behaviour Manifold.Connectors.Provider

  alias Manifold.Connectors.Provider.{
    Error,
    Identity,
    Page,
    RawMessage,
    RemoteMessage,
    SyncCursor,
    Token
  }

  @default_scopes "openid profile offline_access User.Read Mail.Read"
  @immutable_id_preference ~s(IdType="ImmutableId")

  @impl true
  @spec exchange_code(String.t(), String.t(), String.t(), Keyword.t(), Keyword.t()) ::
          {:ok, Token.t()} | {:error, Error.t()}
  def exchange_code(code, verifier, redirect_uri, config, opts) do
    token_request(
      [
        code: code,
        redirect_uri: redirect_uri,
        code_verifier: verifier,
        grant_type: "authorization_code"
      ],
      config,
      opts
    )
  end

  @impl true
  @spec refresh_token(String.t(), Keyword.t(), Keyword.t()) ::
          {:ok, Token.t()} | {:error, Error.t()}
  def refresh_token(refresh_token, config, opts) do
    token_request(
      [refresh_token: refresh_token, grant_type: "refresh_token"],
      config,
      opts
    )
  end

  @impl true
  @spec identity(String.t(), Keyword.t(), Keyword.t()) ::
          {:ok, Identity.t()} | {:error, Error.t()}
  def identity(access_token, config, _opts) do
    with {:ok, base_url} <- fetch_config(config, :base_url),
         {:ok, response} <-
           graph_request(
             :get,
             base_url <> "/me",
             access_token,
             config,
             params: %{"$select" => "id,mail,userPrincipalName"}
           ) do
      normalize_identity_response(response)
    end
  end

  @impl true
  @spec initial_cursors(String.t(), Keyword.t(), Keyword.t()) ::
          {:ok, [SyncCursor.t()]} | {:error, Error.t()}
  def initial_cursors(_access_token, config, _opts) do
    with {:ok, base_url} <- fetch_config(config, :base_url),
         :ok <- validate_graph_url(base_url, base_url) do
      {:ok,
       [
         %SyncCursor{
           scope: "folders",
           phase: "bootstrap",
           page_cursor: base_url <> "/me/mailFolders/delta"
         }
       ]}
    end
  end

  @impl true
  @spec sync_page(String.t(), SyncCursor.t(), Keyword.t(), Keyword.t()) ::
          {:ok, Page.t()} | {:error, Error.t()}
  def sync_page(access_token, %SyncCursor{} = cursor, config, _opts) do
    with {:ok, base_url} <- fetch_config(config, :base_url),
         {:ok, url} <- cursor_url(cursor),
         :ok <- validate_graph_url(url, base_url),
         {:ok, response} <- graph_request(:get, url, access_token, config, []) do
      case normalize_sync_response(response, cursor, base_url) do
        {:error, %Error{code: :cursor_reset}} ->
          {:ok, %Page{cursor: reset_cursor(cursor, base_url)}}

        result ->
          result
      end
    end
  end

  @impl true
  @spec fetch_raw(String.t(), String.t(), Keyword.t(), Keyword.t()) ::
          {:ok, RawMessage.t()} | {:error, Error.t()}
  def fetch_raw(access_token, message_id, config, _opts)
      when is_binary(message_id) and message_id != "" do
    with {:ok, base_url} <- fetch_config(config, :base_url),
         encoded_id = URI.encode(message_id, &URI.char_unreserved?/1),
         {:ok, response} <-
           graph_request(
             :get,
             base_url <> "/me/messages/" <> encoded_id <> "/$value",
             access_token,
             config,
             []
           ) do
      normalize_raw_response(response)
    end
  end

  defp token_request(grant, config, opts) do
    with {:ok, token_url} <- fetch_config(config, :token_url),
         {:ok, client_id} <- fetch_config(config, :client_id),
         {:ok, client_secret} <- fetch_config(config, :client_secret) do
      requested_scopes =
        opts
        |> Keyword.get(
          :required_scopes,
          String.split(Keyword.get(config, :scopes, @default_scopes))
        )
        |> Enum.uniq()
        |> Enum.sort()

      form =
        [
          client_id: client_id,
          client_secret: client_secret,
          scope: Enum.join(requested_scopes, " ")
        ] ++ grant

      request(:post, token_url, config, form: form)
      |> normalize_token_response(
        Keyword.get(opts, :now, DateTime.utc_now()),
        requested_scopes
      )
    end
  end

  defp normalize_token_response(
         {:ok,
          %Req.Response{
            status: status,
            body:
              %{
                "access_token" => access_token,
                "expires_in" => expires_in
              } = body
          }},
         now,
         requested_scopes
       )
       when status in 200..299 and is_binary(access_token) and is_integer(expires_in) and
              is_list(requested_scopes) do
    {:ok,
     %Token{
       access_token: access_token,
       refresh_token: body["refresh_token"],
       expires_at: DateTime.add(now, expires_in, :second),
       scopes: token_scopes(body["scope"], requested_scopes)
     }}
  end

  defp normalize_token_response({:ok, %Req.Response{} = response}, _now, _requested_scopes),
    do: {:error, classify_response(response)}

  defp normalize_token_response({:error, reason}, _now, _requested_scopes),
    do: {:error, transport_error(reason)}

  defp token_scopes(scopes, _requested_scopes) when is_binary(scopes),
    do: String.split(scopes)

  defp token_scopes(_scopes, requested_scopes), do: requested_scopes

  defp normalize_identity_response(%Req.Response{
         status: status,
         body: %{"id" => id} = body
       })
       when status in 200..299 and is_binary(id) do
    case body["mail"] || body["userPrincipalName"] do
      email when is_binary(email) and email != "" ->
        {:ok, %Identity{id: id, email_address: email}}

      _missing ->
        {:error, invalid_response("Microsoft Graph identity did not include an email address")}
    end
  end

  defp normalize_identity_response(%Req.Response{} = response),
    do: {:error, classify_response(response)}

  defp normalize_raw_response(%Req.Response{status: status, body: bytes})
       when status in 200..299 and is_binary(bytes) do
    {:ok, %RawMessage{bytes: bytes}}
  end

  defp normalize_raw_response(%Req.Response{} = response),
    do: {:error, classify_response(response)}

  defp normalize_sync_response(
         %Req.Response{status: status, body: %{"value" => values} = body},
         cursor,
         base_url
       )
       when status in 200..299 and is_list(values) do
    with {:ok, next_cursor} <- advance_cursor(cursor, body, base_url),
         {:ok, messages, discovered_cursors} <-
           normalize_scope(cursor, values, base_url) do
      {:ok,
       %Page{
         cursor: next_cursor,
         messages: messages,
         discovered_cursors: discovered_cursors
       }}
    end
  end

  defp normalize_sync_response(%Req.Response{} = response, _cursor, _base_url),
    do: {:error, classify_response(response)}

  defp advance_cursor(%SyncCursor{} = cursor, %{"@odata.nextLink" => next_link}, base_url)
       when is_binary(next_link) do
    with :ok <- validate_graph_url(next_link, base_url) do
      {:ok, %SyncCursor{cursor | page_cursor: next_link}}
    end
  end

  defp advance_cursor(%SyncCursor{} = cursor, %{"@odata.deltaLink" => delta_link}, base_url)
       when is_binary(delta_link) do
    with :ok <- validate_graph_url(delta_link, base_url) do
      {:ok,
       %SyncCursor{
         cursor
         | phase: "steady",
           page_cursor: nil,
           committed_cursor: delta_link
       }}
    end
  end

  defp advance_cursor(_cursor, _body, _base_url),
    do: {:error, invalid_response("Microsoft Graph delta response did not include a cursor")}

  defp normalize_scope(%SyncCursor{scope: "folders"}, values, base_url) do
    cursors =
      values
      |> Enum.map(&folder_cursor(&1, base_url))

    if Enum.all?(cursors, &match?({:ok, %SyncCursor{}}, &1)) do
      {:ok, [], Enum.map(cursors, fn {:ok, cursor} -> cursor end)}
    else
      {:error, invalid_response("Microsoft Graph folder delta included an invalid folder")}
    end
  end

  defp normalize_scope(
         %SyncCursor{scope: "folder:" <> folder_id, metadata: metadata},
         values,
         _base_url
       )
       when folder_id != "" do
    folder_kind = Map.get(metadata, "folder_kind", "archive")
    messages = Enum.map(values, &normalize_message(&1, folder_id, folder_kind))

    if Enum.all?(messages, &match?({:ok, %RemoteMessage{}}, &1)) do
      {:ok, Enum.map(messages, fn {:ok, message} -> message end), []}
    else
      {:error, invalid_response("Microsoft Graph message delta included an invalid message")}
    end
  end

  defp normalize_scope(_cursor, _values, _base_url) do
    {:error,
     %Error{
       class: :permanent,
       code: :invalid_cursor_scope,
       message: "Microsoft Graph cursor scope is invalid"
     }}
  end

  defp folder_cursor(%{"id" => id, "@removed" => removed}, _base_url)
       when is_binary(id) and id != "" and is_map(removed) do
    {:ok, %SyncCursor{scope: "folder:" <> id, phase: "removed"}}
  end

  defp folder_cursor(%{"id" => id} = folder, base_url) when is_binary(id) and id != "" do
    encoded_id = URI.encode(id, &URI.char_unreserved?/1)

    {:ok,
     %SyncCursor{
       scope: "folder:" <> id,
       phase: "bootstrap",
       metadata: %{"folder_kind" => graph_folder_kind(folder["displayName"])},
       page_cursor: base_url <> "/me/mailFolders/" <> encoded_id <> "/messages/delta"
     }}
  end

  defp folder_cursor(_folder, _base_url), do: :error

  defp normalize_message(%{"id" => id} = message, folder_id, folder_kind)
       when is_binary(id) and id != "" do
    if removed?(message) do
      {:ok,
       %RemoteMessage{
         id: id,
         folder_id: folder_id,
         folder_kind: "membership_tombstone",
         tombstone_kind: :membership,
         deleted?: false
       }}
    else
      with {:ok, received_at} <- parse_optional_datetime(message["receivedDateTime"]) do
        {:ok,
         %RemoteMessage{
           id: id,
           thread_id: message["conversationId"],
           received_at: received_at,
           folder_id: message["parentFolderId"] || folder_id,
           folder_kind: folder_kind,
           read?: message["isRead"] == true,
           starred?: get_in(message, ["flag", "flagStatus"]) == "flagged"
         }}
      end
    end
  end

  defp normalize_message(_message, _folder_id, _folder_kind), do: :error

  defp graph_folder_kind(display_name) when is_binary(display_name) do
    case String.downcase(display_name) do
      "inbox" -> "inbox"
      "archive" -> "archive"
      "deleted items" -> "trash"
      "trash" -> "trash"
      _other -> "archive"
    end
  end

  defp graph_folder_kind(_display_name), do: "archive"

  defp reset_cursor(%SyncCursor{scope: "folders"} = cursor, base_url) do
    %SyncCursor{
      cursor
      | phase: "bootstrap",
        bootstrap_cursor: nil,
        page_cursor: base_url <> "/me/mailFolders/delta",
        committed_cursor: nil
    }
  end

  defp reset_cursor(%SyncCursor{scope: "folder:" <> folder_id} = cursor, base_url) do
    encoded_id = URI.encode(folder_id, &URI.char_unreserved?/1)

    %SyncCursor{
      cursor
      | phase: "bootstrap",
        bootstrap_cursor: nil,
        page_cursor: base_url <> "/me/mailFolders/" <> encoded_id <> "/messages/delta",
        committed_cursor: nil
    }
  end

  defp removed?(%{"@removed" => removed}) when is_map(removed), do: true
  defp removed?(_item), do: false

  defp parse_optional_datetime(nil), do: {:ok, nil}

  defp parse_optional_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      {:error, _reason} -> :error
    end
  end

  defp parse_optional_datetime(_value), do: :error

  defp cursor_url(%SyncCursor{} = cursor) do
    case cursor.page_cursor || cursor.committed_cursor || cursor.bootstrap_cursor do
      url when is_binary(url) and url != "" -> {:ok, url}
      _missing -> {:error, invalid_response("Microsoft Graph cursor URL is missing")}
    end
  end

  defp graph_request(method, url, access_token, config, options) do
    request_options =
      Keyword.merge(
        [
          auth: {:bearer, access_token},
          headers: [{"prefer", @immutable_id_preference}]
        ],
        options
      )

    case request(method, url, config, request_options) do
      {:ok, %Req.Response{} = response} -> {:ok, response}
      {:error, reason} -> {:error, transport_error(reason)}
    end
  end

  defp request(method, url, config, options) do
    options =
      [method: method, url: url, retry: false]
      |> Keyword.merge(options)
      |> Keyword.merge(Keyword.get(config, :req_options, []))

    Req.request(options)
  end

  defp fetch_config(config, key) do
    case Keyword.get(config, key) do
      value when is_binary(value) and value != "" ->
        {:ok, value}

      _missing ->
        {:error,
         %Error{
           class: :permanent,
           code: :provider_not_configured,
           message: "Microsoft Graph is not configured"
         }}
    end
  end

  defp classify_response(%Req.Response{body: %{"error" => "invalid_grant"}}) do
    %Error{
      class: :reconnect,
      code: :invalid_grant,
      message: "Microsoft authorization must be renewed"
    }
  end

  defp classify_response(%Req.Response{status: 410}), do: cursor_reset_error()

  defp classify_response(%Req.Response{status: 401}) do
    %Error{
      class: :reconnect,
      code: :invalid_token,
      message: "Microsoft authorization must be renewed"
    }
  end

  defp classify_response(%Req.Response{body: body} = response) when is_map(body) do
    if graph_error_code?(body, "syncStateNotFound") do
      cursor_reset_error()
    else
      classify_status(response)
    end
  end

  defp classify_response(%Req.Response{} = response), do: classify_status(response)

  defp classify_status(%Req.Response{status: status} = response)
       when status in [429, 500, 502, 503, 504] do
    %Error{
      class: :temporary,
      code: http_code(status),
      message: "Microsoft Graph is temporarily unavailable",
      retry_after_seconds: retry_after(response)
    }
  end

  defp classify_status(%Req.Response{status: 404}) do
    %Error{
      class: :permanent,
      code: :not_found,
      message: "Microsoft Graph item no longer exists"
    }
  end

  defp classify_status(%Req.Response{status: status}) do
    %Error{
      class: :permanent,
      code: http_code(status),
      message: "Microsoft Graph rejected the request"
    }
  end

  defp graph_error_code?(%{"code" => expected}, expected), do: true

  defp graph_error_code?(map, expected) when is_map(map),
    do: Enum.any?(map, fn {_key, value} -> graph_error_code?(value, expected) end)

  defp graph_error_code?(list, expected) when is_list(list),
    do: Enum.any?(list, &graph_error_code?(&1, expected))

  defp graph_error_code?(_value, _expected), do: false

  defp transport_error(_reason) do
    %Error{
      class: :temporary,
      code: :transport_error,
      message: "Microsoft Graph could not be reached"
    }
  end

  defp cursor_reset_error do
    %Error{
      class: :temporary,
      code: :cursor_reset,
      message: "Microsoft Graph delta cursor must be reset"
    }
  end

  defp invalid_response(message) do
    %Error{
      class: :temporary,
      code: :invalid_provider_response,
      message: message
    }
  end

  defp retry_after(response) do
    case Req.Response.get_header(response, "retry-after") do
      [value] ->
        case Integer.parse(value) do
          {seconds, ""} when seconds > 0 -> seconds
          _invalid -> nil
        end

      _missing_or_ambiguous ->
        nil
    end
  end

  defp validate_graph_url(url, base_url) do
    cursor = URI.parse(url)
    base = URI.parse(base_url)

    if valid_https_uri?(cursor) and valid_https_uri?(base) and
         String.downcase(cursor.host) == String.downcase(base.host) and
         cursor.port == base.port do
      :ok
    else
      {:error,
       %Error{
         class: :permanent,
         code: :invalid_cursor_url,
         message: "Microsoft Graph cursor URL has an untrusted authority"
       }}
    end
  end

  defp valid_https_uri?(%URI{
         scheme: "https",
         host: host,
         userinfo: nil,
         fragment: nil
       })
       when is_binary(host) and host != "",
       do: true

  defp valid_https_uri?(_uri), do: false

  defp http_code(status), do: String.to_atom("http_#{status}")
end
