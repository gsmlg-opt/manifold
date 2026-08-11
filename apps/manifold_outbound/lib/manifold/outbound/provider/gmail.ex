defmodule Manifold.Outbound.Provider.Gmail do
  @moduledoc """
  Gmail API outbound provider adapter.

  A transport failure is retryable only when the caller supplies explicit
  evidence that it occurred before transmission. Unknown and post-transmission
  failures are uncertain because Gmail may already have accepted the message.
  """

  @behaviour Manifold.Outbound.Provider

  alias Manifold.Outbound.Provider.{Error, Request, Submission}

  @default_base_url "https://gmail.googleapis.com"
  @send_path "/gmail/v1/users/me/messages/send"
  @safe_req_options [:plug, :receive_timeout, :pool_timeout]
  @rate_limit_reasons ~w(
    dailyLimitExceeded
    quotaExceeded
    rateLimitExceeded
    userRateLimitExceeded
  )

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
           "Gmail access token is not configured"
         )}
    end
  end

  defp submit_with_token(config, raw_message, access_token) do
    base_url = Keyword.get(config, :base_url, @default_base_url)

    request_options =
      config
      |> Keyword.get(:req_options, [])
      |> transport_req_options()
      |> Keyword.put(:url, base_url <> @send_path)
      |> Keyword.put(:auth, {:bearer, access_token})
      |> Keyword.put(:json, %{raw: Base.url_encode64(raw_message, padding: false)})
      |> Keyword.put(:retry, false)
      |> Keyword.put(:redirect, false)

    case Req.post(request_options) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        accepted(body)

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

  defp accepted(%{"id" => id, "threadId" => thread_id})
       when is_binary(id) and id != "" and is_binary(thread_id) and thread_id != "",
       do: accepted(id, thread_id)

  defp accepted(_body), do: invalid_response()

  defp accepted(id, thread_id) do
    {:ok, %Submission{provider_message_id: id, metadata: %{thread_id: thread_id}}}
  end

  defp invalid_response do
    {:error,
     error(
       :uncertain,
       "invalid_response",
       "Gmail may have accepted the message"
     )}
  end

  defp classify_response(%Req.Response{status: status, body: body} = response) do
    cond do
      status == 401 or invalid_grant?(body) ->
        error(
          :permanent,
          "reconnect_required",
          "Gmail authorization must be reconnected",
          status
        )

      status == 403 and insufficient_scope?(body) ->
        error(
          :permanent,
          "insufficient_scope",
          "Gmail authorization requires the send scope",
          status
        )

      status == 403 and rate_limited?(body) ->
        error(
          :transient,
          "rate_limited",
          "Gmail rate limit reached",
          status,
          retry_after(response)
        )

      status == 429 ->
        error(
          :transient,
          "rate_limited",
          "Gmail rate limit reached",
          status,
          retry_after(response)
        )

      status >= 500 ->
        error(
          :transient,
          "provider_unavailable",
          "Gmail service is temporarily unavailable",
          status,
          retry_after(response)
        )

      true ->
        error(
          :permanent,
          "request_rejected",
          "Gmail rejected the request",
          status
        )
    end
  end

  defp classify_transport_failure(%Req.TransportError{
         reason: {:manifold_transport_phase, :pre_transmission, _reason}
       }) do
    error(
      :transient,
      "transport_error",
      "Gmail request could not be transmitted"
    )
  end

  defp classify_transport_failure(_post_or_unknown) do
    error(
      :uncertain,
      "acceptance_unknown",
      "Gmail may have accepted the message"
    )
  end

  defp invalid_grant?(%{"error" => "invalid_grant"}), do: true
  defp invalid_grant?(_body), do: false

  defp insufficient_scope?(%{"error" => "insufficient_scope"}), do: true

  defp insufficient_scope?(body) do
    Enum.any?(provider_reasons(body), &(&1 in ["insufficientPermissions", "insufficient_scope"]))
  end

  defp rate_limited?(body) do
    Enum.any?(provider_reasons(body), &(&1 in @rate_limit_reasons))
  end

  defp provider_reasons(%{"error" => %{"errors" => errors}}) when is_list(errors) do
    Enum.flat_map(errors, fn
      %{"reason" => reason} when is_binary(reason) -> [reason]
      _invalid -> []
    end)
  end

  defp provider_reasons(_body), do: []

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
