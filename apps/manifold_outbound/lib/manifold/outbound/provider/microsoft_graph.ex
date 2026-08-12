defmodule Manifold.Outbound.Provider.MicrosoftGraph do
  @moduledoc """
  Microsoft Graph MIME submission adapter.

  A transport failure is retryable only when it contains explicit evidence that
  no request bytes were transmitted. All other transport and server failures
  are uncertain because Microsoft may already have accepted the message.
  """

  @behaviour Manifold.Outbound.Provider

  alias Manifold.Outbound.Provider.{Error, Request, Submission}

  @default_base_url "https://graph.microsoft.com/v1.0"
  @send_path "/me/sendMail"
  @safe_req_options [:plug, :receive_timeout, :pool_timeout]
  @diagnostic_id ~r/\A[A-Za-z0-9._:-]{1,128}\z/
  @diagnostic_headers [
    {"request-id", "request_id"},
    {"client-request-id", "client_request_id"}
  ]
  @authentication_codes ["invalidauthenticationtoken"]
  @insufficient_scope_codes [
    "authorizationrequestdenied",
    "insufficientpermissions",
    "insufficientscope"
  ]

  @impl true
  def submit(config, %Request{raw_message: raw_message}) when is_list(config) do
    case Keyword.get(config, :access_token) do
      access_token when is_binary(access_token) and access_token != "" ->
        submit_with_token(config, raw_message, access_token)

      _missing ->
        {:error,
         error(
           :permanent,
           "provider_not_configured",
           "Microsoft access token is not configured"
         )}
    end
  end

  defp submit_with_token(config, raw_message, access_token) do
    base_url = Keyword.get(config, :base_url, @default_base_url)

    request_options =
      config
      |> Keyword.get(:req_options, [])
      |> transport_req_options()
      |> Keyword.put(:method, :post)
      |> Keyword.put(:url, String.trim_trailing(base_url, "/") <> @send_path)
      |> Keyword.put(:auth, {:bearer, access_token})
      |> Keyword.put(:body, Base.encode64(raw_message))
      |> Keyword.put(:headers, [{"content-type", "text/plain"}])
      |> Keyword.put(:retry, false)
      |> Keyword.put(:redirect, false)

    case Req.request(request_options) do
      {:ok, %Req.Response{status: 202} = response} ->
        {:ok,
         %Submission{
           provider_message_id: nil,
           metadata: diagnostic_metadata(response)
         }}

      {:ok, %Req.Response{} = response} ->
        {:error, classify_response(response)}

      {:error, reason} ->
        {:error, classify_transport_failure(reason)}
    end
  end

  defp transport_req_options(options) do
    options
    |> Keyword.take(@safe_req_options)
    |> maybe_put_connect_timeout(Keyword.get(options, :connect_options))
  end

  defp maybe_put_connect_timeout(options, connect_options) when is_list(connect_options) do
    case Keyword.fetch(connect_options, :timeout) do
      {:ok, timeout} -> Keyword.put(options, :connect_options, timeout: timeout)
      :error -> options
    end
  end

  defp maybe_put_connect_timeout(options, _connect_options), do: options

  defp diagnostic_metadata(response) do
    Enum.reduce(@diagnostic_headers, %{}, fn {header, metadata_key}, metadata ->
      case Req.Response.get_header(response, header) do
        [value] when is_binary(value) ->
          if Regex.match?(@diagnostic_id, value),
            do: Map.put(metadata, metadata_key, value),
            else: metadata

        _missing_or_ambiguous ->
          metadata
      end
    end)
  end

  defp classify_response(%Req.Response{status: status, body: body} = response) do
    codes = graph_error_codes(body)

    cond do
      status == 429 ->
        error(
          :transient,
          "rate_limited",
          "Microsoft Graph rate limit reached",
          status,
          retry_after(response)
        )

      status in 500..599 ->
        acceptance_unknown(status)

      status in 200..299 ->
        error(
          :uncertain,
          "invalid_response",
          "Microsoft may have accepted the message",
          status
        )

      status == 401 or has_code?(codes, @authentication_codes) ->
        error(
          :permanent,
          "reconnect_required",
          "Microsoft authorization must be reconnected",
          status
        )

      status == 403 and has_code?(codes, @insufficient_scope_codes) ->
        error(
          :permanent,
          "insufficient_scope",
          "Microsoft authorization requires the send scope",
          status
        )

      status == 403 and policy_rejection?(codes) ->
        error(
          :permanent,
          "policy_rejected",
          "Microsoft policy rejected the request",
          status
        )

      status in 400..499 ->
        request_rejected(status)

      true ->
        request_rejected(status)
    end
  end

  defp classify_transport_failure(%Req.TransportError{
         reason: {:manifold_transport_phase, :pre_transmission, _reason}
       }) do
    error(:transient, "transport_error", "Microsoft request could not be transmitted")
  end

  defp classify_transport_failure(_unknown_or_post_dispatch) do
    error(:uncertain, "acceptance_unknown", "Microsoft may have accepted the message")
  end

  defp acceptance_unknown(status) do
    error(
      :uncertain,
      "acceptance_unknown",
      "Microsoft may have accepted the message",
      status
    )
  end

  defp request_rejected(status) do
    error(:permanent, "request_rejected", "Microsoft Graph rejected the request", status)
  end

  defp graph_error_codes(map) when is_map(map) do
    Enum.flat_map(map, fn
      {key, value} when key in ["code", "error"] and is_binary(value) ->
        [canonical_code(value)]

      {_key, value} ->
        graph_error_codes(value)
    end)
  end

  defp graph_error_codes(list) when is_list(list), do: Enum.flat_map(list, &graph_error_codes/1)
  defp graph_error_codes(_value), do: []

  defp canonical_code(code) do
    code
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]/u, "")
  end

  defp has_code?(codes, expected), do: Enum.any?(codes, &(&1 in expected))

  defp policy_rejection?(codes) do
    Enum.any?(codes, fn code ->
      String.contains?(code, "accessdenied") or
        String.contains?(code, "tenant") or
        String.contains?(code, "policy")
    end)
  end

  defp retry_after(response) do
    case Req.Response.get_header(response, "retry-after") do
      [value] -> parse_retry_after(value)
      _missing_or_ambiguous -> nil
    end
  end

  defp parse_retry_after(value) do
    case Integer.parse(value) do
      {seconds, ""} when seconds >= 0 ->
        seconds

      _not_seconds ->
        with {:ok, retry_at} <- Req.Utils.parse_http_date(value),
             seconds when seconds >= 0 <- DateTime.diff(retry_at, DateTime.utc_now(), :second) do
          seconds
        else
          _invalid_or_expired -> nil
        end
    end
  end

  defp error(class, code, message, http_status \\ nil, retry_after \\ nil) do
    %Error{
      class: class,
      code: code,
      message: String.slice(message, 0, 500),
      http_status: http_status,
      retry_after: retry_after
    }
  end
end
