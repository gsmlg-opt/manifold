defmodule Manifold.Connectors.Provider.Gmail do
  @moduledoc """
  Gmail OAuth and mailbox synchronization adapter.

  Initial synchronization freezes a profile `historyId`, scans message IDs, and
  then replays history from that anchor. Gmail history remains the incremental
  source of truth; expired history cursors restart the initial scan.
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

  @default_base_url "https://gmail.googleapis.com"
  @default_token_url "https://oauth2.googleapis.com/token"
  @default_userinfo_url "https://openidconnect.googleapis.com/v1/userinfo"
  @readonly_scope "https://www.googleapis.com/auth/gmail.readonly"
  @mailbox_scope "mailbox"
  @page_size 500

  @rate_limit_reasons ~w(
    dailyLimitExceeded
    quotaExceeded
    rateLimitExceeded
    userRateLimitExceeded
  )

  @impl true
  def exchange_code(code, pkce_verifier, redirect_uri, config, opts) do
    form = [
      client_id: Keyword.get(config, :client_id),
      client_secret: Keyword.get(config, :client_secret),
      code: code,
      code_verifier: pkce_verifier,
      grant_type: "authorization_code",
      redirect_uri: redirect_uri
    ]

    token_request(form, config, opts)
  end

  @impl true
  def refresh_token(refresh_token, config, opts) do
    form = [
      client_id: Keyword.get(config, :client_id),
      client_secret: Keyword.get(config, :client_secret),
      grant_type: "refresh_token",
      refresh_token: refresh_token
    ]

    token_request(form, config, opts)
  end

  @impl true
  def identity(access_token, config, _opts) do
    with {:ok, response} <-
           request(
             :get,
             Keyword.get(config, :userinfo_url, @default_userinfo_url),
             config,
             auth: {:bearer, access_token}
           ),
         {:ok, subject} <- required_string(response.body, "sub"),
         {:ok, email_address} <- required_string(response.body, "email") do
      {:ok,
       %Identity{
         id: subject,
         email_address: email_address
       }}
    end
  end

  @impl true
  def initial_cursors(access_token, config, _opts) do
    with {:ok, profile} <- profile(access_token, config),
         {:ok, history_id} <- required_string(profile, "historyId") do
      {:ok,
       [
         %SyncCursor{
           scope: @mailbox_scope,
           phase: "initial",
           bootstrap_cursor: history_id
         }
       ]}
    end
  end

  @impl true
  def sync_page(
        access_token,
        %SyncCursor{scope: @mailbox_scope, phase: "initial"} = cursor,
        config,
        _opts
      ) do
    params =
      [
        includeSpamTrash: true,
        maxResults: @page_size
      ]
      |> maybe_put(:pageToken, cursor.page_cursor)

    with {:ok, response} <-
           api_request(access_token, :get, "/gmail/v1/users/me/messages", config, params: params),
         {:ok, messages} <- initial_messages(response.body) do
      {:ok,
       %Page{
         messages: messages,
         cursor: next_initial_cursor(cursor, response.body["nextPageToken"])
       }}
    end
  end

  def sync_page(
        access_token,
        %SyncCursor{scope: @mailbox_scope, phase: "incremental"} = cursor,
        config,
        _opts
      ) do
    params =
      [
        startHistoryId: cursor.committed_cursor,
        maxResults: @page_size
      ]
      |> maybe_put(:pageToken, cursor.page_cursor)

    case api_request(access_token, :get, "/gmail/v1/users/me/history", config, params: params) do
      {:ok, response} ->
        with {:ok, messages} <- history_messages(response.body),
             {:ok, next_cursor} <- next_history_cursor(cursor, response.body) do
          {:ok, %Page{messages: messages, cursor: next_cursor}}
        end

      {:error, %Error{code: :not_found}} ->
        reset_expired_history(access_token, config)

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  def sync_page(_access_token, %SyncCursor{}, _config, _opts) do
    {:error, error(:permanent, :invalid_cursor, "Gmail synchronization cursor is invalid")}
  end

  @impl true
  def fetch_raw(access_token, message_id, config, _opts) do
    path = "/gmail/v1/users/me/messages/" <> URI.encode(message_id, &URI.char_unreserved?/1)

    with {:ok, response} <-
           api_request(access_token, :get, path, config, params: [format: "RAW"]),
         {:ok, encoded_raw} <- required_string(response.body, "raw"),
         {:ok, raw} <- decode_raw(encoded_raw),
         {:ok, labels} <- labels(response.body["labelIds"]),
         {:ok, received_at} <- parse_internal_date(response.body["internalDate"]) do
      {:ok,
       %RawMessage{
         bytes: raw,
         received_at: received_at,
         thread_id: optional_string(response.body["threadId"]),
         labels: labels,
         read?: "UNREAD" not in labels,
         starred?: "STARRED" in labels
       }}
    end
  end

  defp token_request(form, config, opts) do
    with :ok <- validate_oauth_config(config),
         {:ok, response} <-
           request(
             :post,
             Keyword.get(config, :token_url, @default_token_url),
             config,
             form: form
           ),
         {:ok, access_token} <- required_string(response.body, "access_token"),
         {:ok, expires_in} <- positive_integer(response.body["expires_in"]) do
      {:ok,
       %Token{
         access_token: access_token,
         refresh_token: optional_string(response.body["refresh_token"]),
         expires_at:
           opts
           |> Keyword.get(:now, DateTime.utc_now())
           |> DateTime.add(expires_in, :second),
         scopes: token_scopes(response.body["scope"], config, opts)
       }}
    end
  end

  defp profile(access_token, config) do
    with {:ok, response} <-
           api_request(access_token, :get, "/gmail/v1/users/me/profile", config) do
      {:ok, response.body}
    end
  end

  defp reset_expired_history(access_token, config) do
    with {:ok, profile} <- profile(access_token, config),
         {:ok, history_id} <- required_string(profile, "historyId") do
      {:ok,
       %Page{
         cursor: %SyncCursor{
           scope: @mailbox_scope,
           phase: "initial",
           bootstrap_cursor: history_id
         }
       }}
    end
  end

  defp initial_messages(%{"messages" => messages}) when is_list(messages) do
    normalize_messages(messages)
  end

  defp initial_messages(body) when is_map(body) do
    if Map.has_key?(body, "messages") do
      invalid_response()
    else
      {:ok, []}
    end
  end

  defp history_messages(body) when is_map(body) do
    case Map.get(body, "history", []) do
      history when is_list(history) ->
        history
        |> Enum.reduce_while({:ok, []}, &normalize_history_record/2)
        |> case do
          {:ok, messages} -> {:ok, Enum.reverse(messages)}
          {:error, %Error{}} = failure -> failure
        end

      _invalid ->
        invalid_response()
    end
  end

  defp normalize_history_record(record, {:ok, messages}) when is_map(record) do
    history_groups = [
      {"messagesAdded", false},
      {"labelsAdded", false},
      {"labelsRemoved", false},
      {"messagesDeleted", true}
    ]

    history_groups
    |> Enum.reduce_while({:ok, messages}, fn {key, deleted?}, {:ok, acc} ->
      case Map.get(record, key, []) do
        entries when is_list(entries) ->
          case normalize_history_entries(entries, deleted?) do
            {:ok, normalized} -> {:cont, {:ok, Enum.reverse(normalized, acc)}}
            {:error, %Error{}} = failure -> {:halt, failure}
          end

        _invalid ->
          {:halt, invalid_response()}
      end
    end)
    |> case do
      {:ok, normalized} -> {:cont, {:ok, normalized}}
      {:error, %Error{}} = failure -> {:halt, failure}
    end
  end

  defp normalize_history_record(_record, _acc), do: {:halt, invalid_response()}

  defp normalize_history_entries(entries, deleted?) do
    entries
    |> Enum.reduce_while({:ok, []}, fn
      %{"message" => message}, {:ok, acc} when is_map(message) ->
        case normalize_message(message, deleted?) do
          {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
          {:error, %Error{}} = failure -> {:halt, failure}
        end

      _invalid, _acc ->
        {:halt, invalid_response()}
    end)
    |> case do
      {:ok, messages} -> {:ok, Enum.reverse(messages)}
      {:error, %Error{}} = failure -> failure
    end
  end

  defp normalize_messages(messages) do
    messages
    |> Enum.reduce_while({:ok, []}, fn message, {:ok, acc} ->
      case normalize_message(message, false) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, %Error{}} = failure -> {:halt, failure}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, %Error{}} = failure -> failure
    end
  end

  defp normalize_message(message, deleted?) when is_map(message) do
    with {:ok, id} <- required_string(message, "id"),
         {:ok, labels} <- labels(message["labelIds"]),
         {:ok, received_at} <- parse_internal_date(message["internalDate"]) do
      {:ok,
       %RemoteMessage{
         id: id,
         thread_id: optional_string(message["threadId"]),
         received_at: received_at,
         labels: labels,
         read?: "UNREAD" not in labels,
         starred?: "STARRED" in labels,
         deleted?: deleted?
       }}
    end
  end

  defp normalize_message(_message, _deleted?), do: invalid_response()

  defp labels(nil), do: {:ok, []}

  defp labels(labels) when is_list(labels) do
    if Enum.all?(labels, &is_binary/1) do
      {:ok, Enum.sort(labels)}
    else
      invalid_response()
    end
  end

  defp labels(_labels), do: invalid_response()

  defp next_initial_cursor(cursor, next_page_token)
       when is_binary(next_page_token) and next_page_token != "" do
    %{cursor | page_cursor: next_page_token}
  end

  defp next_initial_cursor(cursor, _no_next_page) do
    %SyncCursor{
      scope: cursor.scope,
      phase: "incremental",
      committed_cursor: cursor.bootstrap_cursor
    }
  end

  defp next_history_cursor(cursor, %{"nextPageToken" => next_page_token})
       when is_binary(next_page_token) and next_page_token != "" do
    {:ok, %{cursor | page_cursor: next_page_token}}
  end

  defp next_history_cursor(cursor, body) do
    with {:ok, history_id} <- required_string(body, "historyId") do
      {:ok, %{cursor | page_cursor: nil, committed_cursor: history_id}}
    end
  end

  defp api_request(access_token, method, path, config, options \\ []) do
    request_options =
      options
      |> Keyword.put(:auth, {:bearer, access_token})

    request(method, base_url(config) <> path, config, request_options)
  end

  defp request(method, url, config, options) do
    request_options =
      [
        method: method,
        url: url,
        retry: false,
        redirect: false
      ]
      |> Keyword.merge(options)
      |> Keyword.merge(Keyword.get(config, :req_options, []))
      |> Keyword.put(:retry, false)
      |> Keyword.put(:redirect, false)

    case Req.request(request_options) do
      {:ok, %Req.Response{status: status} = response} when status in 200..299 ->
        if is_map(response.body) do
          {:ok, response}
        else
          invalid_response()
        end

      {:ok, %Req.Response{} = response} ->
        {:error, classify_response(response)}

      {:error, _reason} ->
        {:error, error(:temporary, :transport_error, "Gmail request failed")}
    end
  end

  defp classify_response(%Req.Response{status: status, body: body, headers: headers}) do
    cond do
      invalid_grant?(body) ->
        error(:reconnect, :invalid_grant, "Gmail authorization must be reconnected")

      status == 401 ->
        error(:reconnect, :authentication_expired, "Gmail authorization must be reconnected")

      status == 403 and provider_reason(body) in @rate_limit_reasons ->
        error(
          :temporary,
          :rate_limited,
          "Gmail rate limit reached",
          retry_after_seconds(headers)
        )

      status == 403 and provider_reason(body) == "domainPolicy" ->
        error(:permanent, :domain_policy, "Gmail access is blocked by domain policy")

      status == 403 and provider_reason(body) in ["authError", "insufficientPermissions"] ->
        error(:reconnect, :insufficient_scope, "Gmail authorization scope is insufficient")

      status == 429 ->
        error(
          :temporary,
          :rate_limited,
          "Gmail rate limit reached",
          retry_after_seconds(headers)
        )

      status in [500, 502, 503, 504] ->
        error(:temporary, :provider_unavailable, "Gmail service is temporarily unavailable")

      status == 404 ->
        error(:permanent, :not_found, "Gmail resource was not found")

      true ->
        error(:permanent, :provider_rejected, "Gmail rejected the request")
    end
  end

  defp invalid_grant?(%{"error" => "invalid_grant"}), do: true
  defp invalid_grant?(_body), do: false

  defp provider_reason(%{"error" => %{"errors" => [%{"reason" => reason} | _]}})
       when is_binary(reason),
       do: reason

  defp provider_reason(_body), do: nil

  defp retry_after_seconds(headers) do
    headers
    |> header_value("retry-after")
    |> parse_retry_after()
  end

  defp header_value(headers, name) when is_map(headers) do
    case Map.get(headers, name) do
      [value | _] when is_binary(value) -> value
      value when is_binary(value) -> value
      _missing -> nil
    end
  end

  defp header_value(headers, name) when is_list(headers) do
    Enum.find_value(headers, fn
      {header_name, value} when is_binary(header_name) and is_binary(value) ->
        if String.downcase(header_name, :ascii) == name, do: value

      _other ->
        nil
    end)
  end

  defp parse_retry_after(value) when is_binary(value) do
    case Integer.parse(value) do
      {seconds, ""} when seconds > 0 -> seconds
      _invalid -> nil
    end
  end

  defp parse_retry_after(_value), do: nil

  defp decode_raw(encoded) do
    case Base.url_decode64(encoded, padding: false) do
      {:ok, raw} -> {:ok, raw}
      :error -> invalid_response()
    end
  end

  defp parse_internal_date(nil), do: {:ok, nil}

  defp parse_internal_date(value) when is_binary(value) do
    with {milliseconds, ""} <- Integer.parse(value),
         {:ok, datetime} <- DateTime.from_unix(milliseconds, :millisecond) do
      {:ok, datetime}
    else
      _invalid -> invalid_response()
    end
  end

  defp parse_internal_date(_value), do: invalid_response()

  defp required_string(map, key) when is_map(map) do
    case Map.get(map, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _invalid -> invalid_response()
    end
  end

  defp required_string(_value, _key), do: invalid_response()

  defp positive_integer(value) when is_integer(value) and value > 0, do: {:ok, value}
  defp positive_integer(_value), do: invalid_response()

  defp optional_string(value) when is_binary(value) and value != "", do: value
  defp optional_string(_value), do: nil

  defp token_scopes(scope, _config, _opts) when is_binary(scope) do
    String.split(scope, ~r/\s+/, trim: true)
  end

  defp token_scopes(_scope, config, opts) do
    Keyword.get(opts, :required_scopes, Keyword.get(config, :scopes, [@readonly_scope]))
  end

  defp validate_oauth_config(config) do
    if present?(config[:client_id]) and present?(config[:client_secret]) do
      :ok
    else
      {:error, error(:permanent, :provider_not_configured, "Gmail OAuth is not configured")}
    end
  end

  defp present?(value), do: is_binary(value) and value != ""

  defp base_url(config) do
    config
    |> Keyword.get(:base_url, @default_base_url)
    |> String.trim_trailing("/")
  end

  defp maybe_put(keyword, _key, nil), do: keyword
  defp maybe_put(keyword, key, value), do: Keyword.put(keyword, key, value)

  defp invalid_response do
    {:error, error(:permanent, :invalid_provider_response, "Gmail returned an invalid response")}
  end

  defp error(class, code, message, retry_after_seconds \\ nil) do
    %Error{
      class: class,
      code: code,
      message: message,
      retry_after_seconds: retry_after_seconds
    }
  end
end
