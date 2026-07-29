defmodule Manifold.Outbound.Provider.Resend do
  @moduledoc """
  Resend HTTPS provider adapter.
  """

  @behaviour Manifold.Outbound.Provider

  alias Manifold.Outbound.Provider.{Envelope, Error, Event, Submission}

  @default_base_url "https://api.resend.com"
  @timestamp_tolerance_seconds 300

  @event_states %{
    "email.sent" => "sent",
    "email.delivery_delayed" => "delayed",
    "email.delivered" => "delivered",
    "email.bounced" => "bounced",
    "email.failed" => "failed",
    "email.suppressed" => "suppressed",
    "email.complained" => "complained"
  }

  @impl true
  def submit(config, %Envelope{} = envelope) do
    case Keyword.get(config, :api_key) do
      api_key when is_binary(api_key) and api_key != "" ->
        submit_with_key(config, envelope, api_key)

      _missing ->
        {:error,
         %Error{
           class: :permanent,
           code: "provider_not_configured",
           message: "Resend API credentials are not configured"
         }}
    end
  end

  defp submit_with_key(config, envelope, api_key) do
    base_url = Keyword.get(config, :base_url, @default_base_url)

    request_options =
      [
        url: base_url <> "/emails",
        auth: {:bearer, api_key},
        headers: [{"idempotency-key", envelope.idempotency_key}],
        json: payload(envelope),
        retry: false
      ]
      |> Keyword.merge(Keyword.get(config, :req_options, []))

    case Req.post(request_options) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        accepted(body)

      {:ok, %Req.Response{} = response} ->
        {:error, classify_response(response)}

      {:error, reason} ->
        {:error,
         %Error{
           class: :transient,
           code: "transport_error",
           message: transport_message(reason)
         }}
    end
  end

  @impl true
  def verify_webhook(config, headers, raw_body, opts \\ [])
      when is_map(headers) and is_binary(raw_body) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    with :ok <- verify_signature(config, headers, raw_body, now),
         {:ok, payload} <- Jason.decode(raw_body),
         {:ok, event} <- normalize_event(headers, payload) do
      {:ok, event}
    else
      {:error, %Error{}} = failure -> failure
      {:error, _decode_error} -> {:error, webhook_error("invalid_json", "invalid webhook JSON")}
    end
  end

  @spec verify_signature(keyword(), map(), binary(), DateTime.t()) ::
          :ok | {:error, Error.t()}
  def verify_signature(config, headers, raw_body, %DateTime{} = now) do
    with {:ok, id} <- required_header(headers, "svix-id"),
         {:ok, timestamp_value} <- required_header(headers, "svix-timestamp"),
         {:ok, signatures} <- required_header(headers, "svix-signature"),
         {:ok, timestamp} <- parse_timestamp(timestamp_value),
         :ok <- verify_timestamp(timestamp, now),
         {:ok, key} <- signing_key(Keyword.get(config, :webhook_secret)),
         true <- valid_signature?(key, id, timestamp_value, raw_body, signatures) do
      :ok
    else
      false -> {:error, webhook_error("invalid_signature", "invalid webhook signature")}
      {:error, %Error{}} = failure -> failure
    end
  end

  defp normalize_event(headers, %{
         "type" => event_type,
         "created_at" => occurred_at,
         "data" => %{"email_id" => provider_message_id, "to" => recipients} = data
       })
       when is_binary(event_type) and is_binary(provider_message_id) and is_list(recipients) do
    with {:ok, normalized_state} <- normalized_state(event_type),
         {:ok, occurred_at} <- parse_datetime(occurred_at),
         {:ok, provider_event_id} <- required_header(headers, "svix-id") do
      {:ok,
       %Event{
         provider_event_id: provider_event_id,
         provider_message_id: provider_message_id,
         event_type: event_type,
         normalized_state: normalized_state,
         recipient_addresses: Enum.map(recipients, &String.downcase(&1, :ascii)),
         occurred_at: occurred_at,
         metadata: Map.drop(data, ["email_id", "to"])
       }}
    end
  end

  defp normalize_event(_headers, _payload),
    do: {:error, webhook_error("invalid_event", "invalid Resend webhook event")}

  defp normalized_state(event_type) do
    case Map.fetch(@event_states, event_type) do
      {:ok, state} -> {:ok, state}
      :error -> {:error, webhook_error("unsupported_event", "unsupported Resend event type")}
    end
  end

  defp required_header(headers, name) do
    case Map.get(headers, name) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _missing -> {:error, webhook_error("missing_header", "missing webhook signature header")}
    end
  end

  defp parse_timestamp(value) do
    case Integer.parse(value) do
      {timestamp, ""} -> {:ok, timestamp}
      _invalid -> {:error, webhook_error("invalid_timestamp", "invalid webhook timestamp")}
    end
  end

  defp verify_timestamp(timestamp, now) do
    if abs(DateTime.to_unix(now) - timestamp) <= @timestamp_tolerance_seconds do
      :ok
    else
      {:error, webhook_error("stale_timestamp", "webhook timestamp is outside tolerance")}
    end
  end

  defp signing_key("whsec_" <> encoded) do
    case Base.decode64(encoded) do
      {:ok, key} -> {:ok, key}
      :error -> {:error, webhook_error("invalid_secret", "invalid webhook signing secret")}
    end
  end

  defp signing_key(_secret),
    do: {:error, webhook_error("invalid_secret", "invalid webhook signing secret")}

  defp valid_signature?(key, id, timestamp, body, signatures) do
    expected = :crypto.mac(:hmac, :sha256, key, "#{id}.#{timestamp}.#{body}")

    signatures
    |> String.split()
    |> Enum.any?(fn
      "v1," <> encoded ->
        case Base.decode64(encoded) do
          {:ok, candidate} when byte_size(candidate) == byte_size(expected) ->
            :crypto.hash_equals(candidate, expected)

          _invalid ->
            false
        end

      _other ->
        false
    end)
  end

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} ->
        {:ok, datetime}

      {:error, _reason} ->
        {:error, webhook_error("invalid_event_time", "invalid event timestamp")}
    end
  end

  defp parse_datetime(_value),
    do: {:error, webhook_error("invalid_event_time", "invalid event timestamp")}

  defp webhook_error(code, message) do
    %Error{class: :permanent, code: code, message: message}
  end

  defp payload(envelope) do
    %{
      from: envelope.from,
      to: envelope.to,
      cc: envelope.cc,
      bcc: envelope.bcc,
      subject: envelope.subject,
      text: envelope.text,
      headers: threading_headers(envelope)
    }
  end

  defp threading_headers(envelope) do
    %{}
    |> maybe_header("In-Reply-To", envelope.in_reply_to)
    |> maybe_header("References", Enum.join(envelope.references, " "))
  end

  defp maybe_header(headers, _name, value) when value in [nil, ""], do: headers
  defp maybe_header(headers, name, value), do: Map.put(headers, name, value)

  defp accepted(%{"id" => id}) when is_binary(id) and id != "" do
    {:ok, %Submission{provider_message_id: id, metadata: %{}}}
  end

  defp accepted(_body) do
    {:error,
     %Error{
       class: :transient,
       code: "invalid_provider_response",
       message: "Resend response did not include a message ID"
     }}
  end

  defp classify_response(%Req.Response{status: 409, body: body}) do
    code = provider_code(body, "http_409")

    class =
      if code == "concurrent_idempotent_requests" do
        :transient
      else
        :permanent
      end

    response_error(class, 409, code, body)
  end

  defp classify_response(%Req.Response{status: 429, body: body} = response) do
    response_error(
      :transient,
      429,
      provider_code(body, "http_429"),
      body,
      retry_after(response)
    )
  end

  defp classify_response(%Req.Response{status: status, body: body}) when status >= 500 do
    response_error(:transient, status, provider_code(body, "http_#{status}"), body)
  end

  defp classify_response(%Req.Response{status: status, body: body}) do
    response_error(:permanent, status, provider_code(body, "http_#{status}"), body)
  end

  defp response_error(class, status, code, body, retry_after \\ nil) do
    %Error{
      class: class,
      code: code,
      message: provider_message(body, "Resend request failed"),
      http_status: status,
      retry_after: retry_after
    }
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

  defp provider_code(%{"name" => name}, _default) when is_binary(name), do: name
  defp provider_code(%{"code" => code}, _default) when is_binary(code), do: code
  defp provider_code(_body, default), do: default

  defp provider_message(%{"message" => message}, _default) when is_binary(message),
    do: String.slice(message, 0, 500)

  defp provider_message(_body, default), do: default

  defp transport_message(%{reason: reason}), do: "Resend transport failed: #{inspect(reason)}"
  defp transport_message(reason), do: "Resend transport failed: #{inspect(reason)}"
end
