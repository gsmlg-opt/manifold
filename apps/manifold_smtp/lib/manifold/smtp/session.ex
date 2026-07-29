defmodule Manifold.SMTP.Session do
  @moduledoc """
  gen_smtp callback module for inbound SMTP sessions.
  """

  @behaviour :gen_smtp_server_session

  alias Manifold.Core.Error
  alias Manifold.SMTP.Admission

  defstruct [:peer_ip, :helo, :mail_from, :admission, routes: [], recipients: [], options: []]

  @impl true
  def init(_hostname, _session_count, peername, opts) do
    peer_ip = peer_to_string(peername)
    admission = Keyword.get(opts, :admission)
    state = %__MODULE__{peer_ip: peer_ip, admission: admission, options: opts}

    case acquire_connection(admission, peer_ip) do
      :ok -> {:ok, "Manifold SMTP ready", state}
      {:error, _reason} -> {:stop, :rate_limited, "421 4.7.0 connection limit exceeded"}
    end
  end

  @impl true
  def handle_HELO(hostname, state) do
    {:ok, max_message_bytes(state), %{reset_transaction(state) | helo: to_string(hostname)}}
  end

  @impl true
  def handle_EHLO(hostname, extensions, state) do
    extensions =
      extensions
      |> reject_extension("SMTPUTF8")
      |> reject_extension("AUTH")
      |> put_extension({~c"SIZE", Integer.to_charlist(max_message_bytes(state))})
      |> put_extension({~c"8BITMIME", true})
      |> put_extension({~c"PIPELINING", true})
      |> maybe_put_starttls(state)

    {:ok, extensions, %{reset_transaction(state) | helo: to_string(hostname)}}
  end

  @impl true
  def handle_MAIL(from, state) do
    state = reset_transaction(state)

    case allow_transaction(state.admission, state.peer_ip) do
      :ok ->
        case Manifold.Core.Address.parse(to_string(from), allow_null_sender: true) do
          {:ok, :null_sender} -> {:ok, %{state | mail_from: ""}}
          {:ok, address} -> {:ok, %{state | mail_from: address.original}}
          {:error, _error} -> {:error, "501 5.1.3 invalid sender address syntax", state}
        end

      {:error, _reason} ->
        {:error, "451 4.7.0 transaction rate limit exceeded", state}
    end
  end

  @impl true
  def handle_MAIL_extension(extension, state) do
    extension = String.upcase(to_string(extension), :ascii)

    cond do
      String.starts_with?(extension, "SIZE=") -> {:ok, state}
      extension == "BODY=8BITMIME" -> {:ok, state}
      true -> :error
    end
  end

  @impl true
  def handle_RCPT(to, state) do
    if length(state.recipients) >= max_recipients(state) do
      {:error, "452 4.3.1 too many recipients", state}
    else
      resolve_recipient(to, state)
    end
  end

  @impl true
  def handle_RCPT_extension(_extension, _state), do: :error

  @impl true
  def handle_DATA(_from, _to, data, state) do
    :telemetry.execute([:manifold, :smtp, :transaction, :start], %{raw_size: byte_size(data)}, %{
      peer_ip: state.peer_ip
    })

    if byte_size(data) > max_message_bytes(state) do
      emit_stop(data, state, :message_too_large)
      {:error, "552 5.3.4 message too large", reset_transaction(state)}
    else
      accept_data(data, state)
    end
  end

  @impl true
  def handle_RSET(state), do: reset_transaction(state)

  @impl true
  def handle_VRFY(_address, state), do: {:error, "252 cannot verify user", state}

  @impl true
  def handle_STARTTLS(state), do: state

  @impl true
  def handle_other(_verb, _args, state), do: {"502 command not implemented", state}

  @impl true
  def handle_error(class, _reason, state)
      when class in [:data_rejected, :data_receive_error] do
    {:ok, reset_transaction(state)}
  end

  def handle_error(_class, _reason, state), do: {:ok, state}

  @impl true
  def code_change(_old_vsn, state, _extra), do: {:ok, state}

  @impl true
  def terminate(reason, state) do
    release_connection(state.admission)
    {:ok, reason, state}
  end

  defp resolve_recipient(to, state) do
    resolver = Keyword.get(state.options, :resolver, Manifold.Accounts)

    case resolver.resolve_recipient(to_string(to)) do
      {:ok, route} ->
        {:ok,
         %{
           state
           | recipients: state.recipients ++ [route.original_recipient],
             routes: state.routes ++ [route]
         }}

      {:error, %Error{reason: :invalid_address}} ->
        {:error, "501 5.1.3 invalid recipient address syntax", state}

      {:error, %Error{class: :permanent}} ->
        {:error, "550 5.1.1 unknown recipient", state}

      {:error, %Error{class: :temporary}} ->
        {:error, "451 4.3.0 temporary recipient lookup failure", state}

      {:error, _reason} ->
        {:error, "451 4.3.0 temporary recipient lookup failure", state}
    end
  end

  defp accept_data(data, state) do
    ingest = Keyword.get(state.options, :ingest, Manifold.Ingest)

    attrs = %{
      peer_ip: state.peer_ip,
      helo: state.helo,
      envelope_from: state.mail_from,
      original_recipients: state.recipients,
      received_at: DateTime.utc_now()
    }

    case ingest.accept_transport(data, attrs, state.routes) do
      {:ok, delivery} ->
        emit_stop(data, state, :accepted, %{ingest_id: delivery.ingest_id})

        {:ok, "2.0.0 accepted as #{delivery.ingest_id}", reset_transaction(state)}

      {:error, %Error{reason: :insufficient_spool_capacity}} ->
        emit_stop(data, state, :insufficient_spool_capacity)
        {:error, "452 4.3.1 insufficient spool capacity", reset_transaction(state)}

      {:error, %Error{reason: :message_too_large}} ->
        emit_stop(data, state, :message_too_large)
        {:error, "552 5.3.4 message too large", reset_transaction(state)}

      {:error, _error} ->
        emit_stop(data, state, :local_accept_failure)
        {:error, "451 4.3.0 local accept failure", reset_transaction(state)}
    end
  end

  defp emit_stop(data, state, result, extra_metadata \\ %{}) do
    metadata =
      Map.merge(
        %{peer_ip: state.peer_ip, result: result},
        extra_metadata
      )

    :telemetry.execute(
      [:manifold, :smtp, :transaction, :stop],
      %{raw_size: byte_size(data)},
      metadata
    )
  end

  defp reset_transaction(state), do: %{state | mail_from: nil, routes: [], recipients: []}

  defp max_message_bytes(state), do: Keyword.fetch!(state.options, :max_message_bytes)

  defp max_recipients(state), do: Keyword.fetch!(state.options, :max_recipients)

  defp reject_extension(extensions, name) do
    name = name |> to_string() |> String.upcase(:ascii)

    Enum.reject(extensions, fn
      {extension, _value} -> String.upcase(to_string(extension), :ascii) == name
      extension -> String.upcase(to_string(extension), :ascii) == name
    end)
  end

  defp put_extension(extensions, {name, value}) do
    [{name, value} | reject_extension(extensions, name)]
  end

  defp maybe_put_starttls(extensions, state) do
    if Keyword.get(state.options, :tls_enabled?, false) do
      put_extension(extensions, {~c"STARTTLS", true})
    else
      reject_extension(extensions, "STARTTLS")
    end
  end

  defp acquire_connection(nil, _peer_ip), do: :ok

  defp acquire_connection(admission, peer_ip),
    do: Admission.acquire_connection(peer_ip, self(), admission)

  defp allow_transaction(nil, _peer_ip), do: :ok
  defp allow_transaction(admission, peer_ip), do: Admission.allow_transaction(peer_ip, admission)

  defp release_connection(nil), do: :ok
  defp release_connection(admission), do: Admission.release_connection(self(), admission)

  defp peer_to_string(peername) do
    peername
    |> :inet.ntoa()
    |> to_string()
  end
end
