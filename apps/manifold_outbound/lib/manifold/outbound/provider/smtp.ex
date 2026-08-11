defmodule Manifold.Outbound.Provider.SMTP do
  @moduledoc """
  Authenticated SMTP outbound provider adapter.

  The checked-out submission method is runtime-only credential material. SMTP
  replies are normalized before crossing the provider boundary so credentials,
  message bytes, and server response details cannot enter persisted errors.
  """

  @behaviour Manifold.Outbound.Provider

  alias Manifold.Connectors.Provider.Error, as: ConnectorError
  alias Manifold.Connectors.SMTP.Client
  alias Manifold.Connectors.SubmissionMethod
  alias Manifold.Core.Address
  alias Manifold.Outbound.Provider.{Error, Request, Submission}

  @impl true
  def submit(config, %Request{} = request) when is_list(config) do
    transport = Keyword.get(config, :transport, Client)

    with {:ok, method} <- submission_method(config, request),
         {:ok, message_id} <- validated_message_id(request),
         {:ok, envelope} <- smtp_envelope(request, method),
         {:ok, settings} <- connection_settings(method),
         {:ok, conn} <- connect(transport, settings) do
      result =
        try do
          transport.submit(conn, envelope)
        after
          best_effort_quit(transport, conn)
        end

      normalize_result(result, message_id)
    else
      {:error, %ConnectorError{} = error} -> {:error, normalize_error(error)}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  def submit(_config, %Request{}) do
    {:error, provider_error(:permanent, "provider_not_configured")}
  end

  defp submission_method(config, request) do
    case Keyword.get(config, :submission_method) do
      %SubmissionMethod{
        id: id,
        kind: "smtp",
        email_address: sender,
        credential: {:password, password},
        config: settings
      } = method
      when id == request.send_method_id and is_binary(sender) and sender != "" and
             is_binary(password) and password != "" and is_map(settings) ->
        {:ok, method}

      _invalid ->
        {:error, provider_error(:permanent, "provider_not_configured")}
    end
  end

  defp connection_settings(%SubmissionMethod{
         credential: {:password, password},
         config: config
       }) do
    required = [:host, :port, :tls_mode, :username]

    if Enum.all?(required, &Map.has_key?(config, &1)) do
      {:ok, Map.put(config, :password, password)}
    else
      {:error, provider_error(:permanent, "provider_not_configured")}
    end
  end

  defp smtp_envelope(request, method) do
    recipients = request.envelope.to ++ request.envelope.cc ++ request.envelope.bcc

    with {:ok, sender} <- envelope_address(method.email_address),
         {:ok, recipients} <- envelope_addresses(recipients) do
      {:ok,
       %{
         envelope_from: sender,
         recipients: recipients,
         raw_message: request.raw_message
       }}
    end
  end

  defp envelope_addresses(addresses) when is_list(addresses) and addresses != [] do
    Enum.reduce_while(addresses, {:ok, []}, fn value, {:ok, acc} ->
      case envelope_address(value) do
        {:ok, address} -> {:cont, {:ok, [address | acc]}}
        {:error, %Error{} = error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, addresses} -> {:ok, Enum.reverse(addresses)}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp envelope_addresses(_addresses),
    do: {:error, provider_error(:permanent, "invalid_envelope_address")}

  defp envelope_address(value) when is_binary(value) do
    if String.contains?(value, ["\r", "\n", <<0>>]) do
      {:error, provider_error(:permanent, "invalid_envelope_address")}
    else
      value
      |> mailbox_address()
      |> Address.parse()
      |> case do
        {:ok, parsed} -> {:ok, parsed.original}
        {:error, _reason} -> {:error, provider_error(:permanent, "invalid_envelope_address")}
      end
    end
  end

  defp envelope_address(_value),
    do: {:error, provider_error(:permanent, "invalid_envelope_address")}

  defp mailbox_address(value) do
    case Regex.run(~r/\A[^<>]*<([^<>]+)>\z/u, String.trim(value), capture: :all_but_first) do
      [address] -> address
      nil -> value
    end
  end

  defp validated_message_id(%Request{
         envelope: %{message_id: message_id},
         raw_message: raw_message
       })
       when is_binary(message_id) and is_binary(raw_message) do
    if valid_message_id?(message_id) and exact_message_id_header?(raw_message, message_id) do
      {:ok, message_id}
    else
      {:error, provider_error(:permanent, "invalid_message_id")}
    end
  end

  defp validated_message_id(_request) do
    {:error, provider_error(:permanent, "invalid_message_id")}
  end

  defp valid_message_id?(message_id) do
    byte_size(message_id) <= 986 and
      Regex.match?(
        ~r/\A<[A-Za-z0-9!#$%&'*+\-\/?=^_`{|}~]+(?:\.[A-Za-z0-9!#$%&'*+\-\/?=^_`{|}~]+)*@[A-Za-z0-9!#$%&'*+\-\/?=^_`{|}~]+(?:\.[A-Za-z0-9!#$%&'*+\-\/?=^_`{|}~]+)*>\z/,
        message_id
      )
  end

  defp exact_message_id_header?(raw_message, message_id) do
    case :binary.split(raw_message, "\r\n\r\n") do
      [headers, _body] ->
        headers
        |> String.split("\r\n")
        |> Enum.count(&(&1 == "Message-ID: #{message_id}")) == 1

      _missing_separator ->
        false
    end
  end

  defp normalize_result({:ok, %{response: _response}}, message_id) do
    digest = :crypto.hash(:sha256, message_id) |> Base.url_encode64(padding: false)

    {:ok,
     %Submission{
       provider_message_id: "smtp-#{digest}",
       metadata: %{smtp_status: 250}
     }}
  end

  defp normalize_result({:error, %ConnectorError{} = error}, _message_id),
    do: {:error, normalize_error(error)}

  defp normalize_result(_unexpected, _message_id) do
    {:error, provider_error(:uncertain, "acceptance_unknown")}
  end

  defp normalize_error(%ConnectorError{} = error) do
    class =
      case error.class do
        :temporary -> :transient
        :uncertain -> :uncertain
        class when class in [:permanent, :reconnect] -> :permanent
      end

    provider_error(class, normalize_code(error.code), error.retry_after_seconds)
  end

  defp normalize_code(code) when is_atom(code), do: Atom.to_string(code)
  defp normalize_code(_code), do: "smtp_error"

  defp connect(transport, settings) do
    case transport.connect(settings) do
      {:ok, conn} -> {:ok, conn}
      {:error, %ConnectorError{} = error} -> {:error, error}
      {:error, reason} -> {:error, raw_connect_error(reason)}
      _unexpected -> {:error, provider_error(:transient, "transport_error")}
    end
  rescue
    _exception -> {:error, provider_error(:transient, "transport_error")}
  catch
    _kind, _reason -> {:error, provider_error(:transient, "transport_error")}
  end

  defp raw_connect_error({:unsupported_tls_mode, _mode}),
    do: provider_error(:permanent, "invalid_config")

  defp raw_connect_error({:invalid_config, _reason}),
    do: provider_error(:permanent, "invalid_config")

  defp raw_connect_error(:invalid_config), do: provider_error(:permanent, "invalid_config")
  defp raw_connect_error(_reason), do: provider_error(:transient, "transport_error")

  defp provider_error(class, code, retry_after \\ nil) do
    message =
      case class do
        :transient -> "SMTP submission temporarily failed"
        :permanent -> "SMTP submission was rejected"
        :uncertain -> "SMTP may have accepted the message"
      end

    %Error{class: class, code: code, message: message, retry_after: retry_after}
  end

  defp best_effort_quit(transport, conn) do
    transport.quit(conn)
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end
end
