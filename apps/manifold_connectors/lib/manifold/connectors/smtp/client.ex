defmodule Manifold.Connectors.SMTP.Client do
  @moduledoc false

  @behaviour Manifold.Connectors.SMTP.Transport

  alias Manifold.Connectors.Provider.Error

  defstruct [:socket, :buffer]

  @connect_timeout 15_000
  @recv_timeout 30_000

  @impl true
  def connect(settings) when is_map(settings) do
    host = settings |> Map.fetch!(:host) |> normalize_host()
    port = normalize_port(Map.fetch!(settings, :port))
    tls_mode = Map.fetch!(settings, :tls_mode)
    username = settings |> Map.fetch!(:username) |> normalize_text()
    password = Map.fetch!(settings, :password)

    with {:ok, host} <- require_host(host),
         {:ok, port} <- require_port(port),
         {:ok, conn} <- open_and_greet_safe(host, port, tls_mode),
         {:ok, conn} <- ehlo(conn, host),
         {:ok, conn} <- maybe_starttls(conn, host, tls_mode),
         {:ok, conn} <- authenticate(conn, username, password) do
      {:ok, conn}
    end
  end

  @impl true
  def quit(conn) do
    conn = get_conn(conn)
    _ = send_command(conn, "QUIT")
    close_socket(conn.socket)
    delete_conn()
    :ok
  end

  @impl true
  def submit(conn, submission) when is_map(submission) do
    with {:ok, envelope_from} <- validate_address(Map.get(submission, :envelope_from)),
         {:ok, recipients} <- validate_recipients(Map.get(submission, :recipients)),
         {:ok, raw_message} <- validate_raw_message(Map.get(submission, :raw_message)) do
      do_submit(get_conn(conn), envelope_from, recipients, raw_message)
    end
  end

  defp do_submit(conn, envelope_from, recipients, raw_message) do
    with {:ok, conn} <- mail_from(conn, envelope_from),
         {:ok, conn} <- recipients(conn, recipients),
         {:ok, conn} <- begin_data(conn) do
      transmit_message(conn, raw_message)
    end
  end

  defp mail_from(conn, envelope_from) do
    case send_command(conn, "MAIL FROM:<#{envelope_from}>") do
      {:ok, conn, code, _lines} when code in 200..299 ->
        {:ok, conn}

      {:ok, conn, code, _lines} ->
        reset_transaction(conn)
        {:error, command_rejected_error(code, :sender_rejected, "SMTP rejected the sender")}

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp recipients(conn, recipients) do
    Enum.reduce_while(recipients, {:ok, conn}, fn recipient, {:ok, conn} ->
      case send_command(conn, "RCPT TO:<#{recipient}>") do
        {:ok, conn, code, _lines} when code in 200..299 ->
          {:cont, {:ok, conn}}

        {:ok, conn, code, _lines} ->
          reset_transaction(conn)

          {:halt,
           {:error,
            command_rejected_error(code, :recipient_rejected, "SMTP rejected a recipient")}}

        {:error, %Error{} = error} ->
          {:halt, {:error, error}}
      end
    end)
  end

  defp begin_data(conn) do
    case send_command(conn, "DATA") do
      {:ok, conn, 354, _lines} ->
        {:ok, conn}

      {:ok, conn, code, _lines} ->
        reset_transaction(conn)
        {:error, command_rejected_error(code, :data_rejected, "SMTP rejected message data")}

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp transmit_message(conn, raw_message) do
    framed = frame_message(raw_message)

    case send_data(conn.socket, framed) do
      :ok -> receive_acceptance(conn)
      {:error, reason} -> {:error, phase_error(:before_terminator, :send_failed, reason)}
    end
  end

  defp receive_acceptance(conn) do
    case recv_reply(conn) do
      {:ok, conn, 250, lines} ->
        put_conn(conn)
        {:ok, %{response: format_response(250, lines)}}

      {:ok, _conn, code, _lines} ->
        {:error, command_rejected_error(code, :message_rejected, "SMTP rejected the message")}

      {:error, _reason} ->
        close_socket(conn.socket)
        delete_conn()

        {:error,
         %Error{
           class: :uncertain,
           code: :acceptance_unknown,
           message: "SMTP may have accepted the message"
         }}
    end
  end

  defp reset_transaction(conn) do
    case send_command(conn, "RSET") do
      {:ok, updated, code, _lines} when code in 200..299 -> put_conn(updated)
      _failed -> close_socket(conn.socket)
    end

    :ok
  end

  defp frame_message(raw_message) do
    normalized = String.replace(raw_message, ~r/\r\n|\r|\n/, "\r\n")

    dot_stuffed =
      normalized
      |> String.split("\r\n", trim: false)
      |> Enum.map_join("\r\n", fn
        "." <> _rest = line -> "." <> line
        line -> line
      end)

    if String.ends_with?(dot_stuffed, "\r\n") do
      dot_stuffed <> ".\r\n"
    else
      dot_stuffed <> "\r\n.\r\n"
    end
  end

  defp validate_recipients(recipients) when is_list(recipients) and recipients != [] do
    Enum.reduce_while(recipients, {:ok, []}, fn recipient, {:ok, acc} ->
      case validate_address(recipient) do
        {:ok, address} -> {:cont, {:ok, [address | acc]}}
        {:error, %Error{} = error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, addresses} -> {:ok, Enum.reverse(addresses)}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp validate_recipients(_recipients), do: invalid_envelope_address()

  defp validate_address(address) when is_binary(address) and address != "" do
    if String.contains?(address, ["\r", "\n", <<0>>]) do
      invalid_envelope_address()
    else
      {:ok, address}
    end
  end

  defp validate_address(_address), do: invalid_envelope_address()

  defp invalid_envelope_address do
    {:error,
     %Error{
       class: :permanent,
       code: :invalid_envelope_address,
       message: "SMTP envelope address is invalid"
     }}
  end

  defp validate_raw_message(raw_message) when is_binary(raw_message), do: {:ok, raw_message}

  defp validate_raw_message(_raw_message) do
    {:error,
     %Error{
       class: :permanent,
       code: :invalid_message,
       message: "SMTP message is invalid"
     }}
  end

  defp command_rejected_error(code, error_code, message) do
    %Error{
      class: if(code in 500..599, do: :permanent, else: :temporary),
      code: error_code,
      message: message
    }
  end

  defp phase_error(:before_terminator, code, _reason) do
    %Error{
      class: :temporary,
      code: code,
      message: "SMTP connection failed before message acceptance"
    }
  end

  defp format_response(code, [line | _rest]), do: "#{code} #{String.slice(line, 0, 500)}"
  defp format_response(code, []), do: Integer.to_string(code)

  defp open_and_greet_safe(host, port, tls_mode) do
    open_and_greet(host, port, tls_mode)
  rescue
    e in [ArgumentError, ErlangError, FunctionClauseError] ->
      {:error, connect_failed_error(e)}
  catch
    :error, :badarg ->
      {:error, connect_failed_error(:badarg)}

    :exit, :badarg ->
      {:error, connect_failed_error(:badarg)}

    :exit, {:badarg, _} = reason ->
      {:error, connect_failed_error(reason)}
  end

  defp open_and_greet(host, port, tls_mode)
       when tls_mode in ["ssl", "tls"] and is_binary(host) and is_integer(port) do
    host_charlist = String.to_charlist(host)

    with {:ok, socket} <-
           :ssl.connect(host_charlist, port, ssl_opts(host_charlist), @connect_timeout) do
      read_greeting(%__MODULE__{socket: socket, buffer: ""})
    end
  end

  defp open_and_greet(host, port, "starttls") when is_binary(host) and is_integer(port) do
    host_charlist = String.to_charlist(host)

    with {:ok, tcp} <- :gen_tcp.connect(host_charlist, port, tcp_opts(), @connect_timeout) do
      read_greeting(%__MODULE__{socket: {:tcp, tcp}, buffer: ""})
    end
  end

  defp open_and_greet(_host, _port, tls_mode) do
    {:error, {:unsupported_tls_mode, tls_mode}}
  end

  defp read_greeting(conn) do
    case recv_reply(conn) do
      {:ok, conn, code, _lines} when code in [220] ->
        put_conn(conn)
        {:ok, conn}

      {:ok, conn, code, _lines} ->
        close_socket(conn.socket)

        {:error,
         %Error{
           class: :temporary,
           code: :bad_greeting,
           message: "Unexpected SMTP greeting #{code}"
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ehlo(conn, host) do
    conn = get_conn(conn)

    case send_command(conn, "EHLO #{ehlo_name(host)}") do
      {:ok, conn, code, _lines} when code in [250] ->
        put_conn(conn)
        {:ok, conn}

      {:ok, conn, code, _lines} ->
        close_socket(conn.socket)

        {:error,
         %Error{
           class: :temporary,
           code: :ehlo_failed,
           message: "SMTP EHLO failed #{code}"
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_starttls(conn, _host, tls_mode) when tls_mode in ["ssl", "tls"], do: {:ok, conn}

  defp maybe_starttls(conn, host, "starttls") do
    conn = get_conn(conn)
    host_charlist = String.to_charlist(host)

    with {:ok, conn, 220, _lines} <- send_command(conn, "STARTTLS"),
         {:tcp, tcp} <- conn.socket,
         {:ok, ssl} <- :ssl.connect(tcp, ssl_opts(host_charlist), @connect_timeout),
         conn <- %{conn | socket: ssl, buffer: ""},
         {:ok, conn} <- ehlo(conn, host) do
      put_conn(conn)
      {:ok, conn}
    else
      {:ok, conn, code, _lines} ->
        close_socket(conn.socket)

        {:error,
         %Error{
           class: :temporary,
           code: :starttls_failed,
           message: "SMTP STARTTLS failed #{code}"
         }}

      {:error, %Error{} = error} ->
        {:error, error}

      {:error, reason} ->
        {:error, connect_failed_error(reason)}

      other ->
        {:error, connect_failed_error(other)}
    end
  end

  defp authenticate(conn, username, password) do
    conn = get_conn(conn)

    case try_auth_login(conn, username, password) do
      {:ok, conn} ->
        {:ok, conn}

      {:fallback_plain, conn} ->
        try_auth_plain(conn, username, password)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp try_auth_login(conn, username, password) do
    case send_command(conn, "AUTH LOGIN") do
      {:ok, conn, 334, _} ->
        with {:ok, conn, 334, _} <- send_command(conn, Base.encode64(username)),
             {:ok, conn, 235, _} <- send_command(conn, Base.encode64(password)) do
          put_conn(conn)
          {:ok, conn}
        else
          {:ok, conn, _code, _lines} ->
            close_socket(conn.socket)
            {:error, auth_failed_error()}

          {:error, reason} ->
            {:error, reason}
        end

      {:ok, conn, _code, _lines} ->
        {:fallback_plain, conn}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp try_auth_plain(conn, username, password) do
    payload = Base.encode64(<<0, username::binary, 0, password::binary>>)

    case send_command(conn, "AUTH PLAIN #{payload}") do
      {:ok, conn, 235, _} ->
        put_conn(conn)
        {:ok, conn}

      {:ok, conn, _code, _lines} ->
        close_socket(conn.socket)
        {:error, auth_failed_error()}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp auth_failed_error do
    %Error{
      class: :reconnect,
      code: :auth_failed,
      message: "SMTP authentication failed"
    }
  end

  defp send_command(conn, text) do
    case send_data(conn.socket, text <> "\r\n") do
      :ok ->
        recv_reply(conn)

      {:error, reason} ->
        {:error,
         %Error{
           class: :temporary,
           code: :send_failed,
           message: "SMTP send failed: #{inspect(reason)}"
         }}
    end
  end

  defp recv_reply(%__MODULE__{} = conn, acc \\ []) do
    case recv_line(conn) do
      {:ok, conn, line} ->
        case parse_reply_line(line) do
          {:final, code, text} ->
            {:ok, conn, code, Enum.reverse([text | acc])}

          {:continued, _code, text} ->
            recv_reply(conn, [text | acc])

          :invalid ->
            {:error,
             %Error{
               class: :temporary,
               code: :bad_reply,
               message: "Unexpected SMTP reply"
             }}
        end

      {:error, :timeout} ->
        {:error, %Error{class: :temporary, code: :timeout, message: "SMTP receive timed out"}}

      {:error, reason} ->
        {:error,
         %Error{
           class: :temporary,
           code: :recv_failed,
           message: "SMTP receive failed: #{inspect(reason)}"
         }}
    end
  end

  defp parse_reply_line(line) do
    case Regex.run(~r/^(\d{3})([ \-])(.*)$/, line) do
      [_, code, " ", text] -> {:final, String.to_integer(code), text}
      [_, code, "-", text] -> {:continued, String.to_integer(code), text}
      _ -> :invalid
    end
  end

  defp recv_line(%__MODULE__{buffer: buffer} = conn) do
    case :binary.split(buffer, "\r\n") do
      [line, rest] ->
        {:ok, %{conn | buffer: rest}, line}

      [_] ->
        case recv_data(conn.socket) do
          {:ok, data} ->
            recv_line(%{conn | buffer: buffer <> data})

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp recv_data({:tcp, socket}) do
    case :gen_tcp.recv(socket, 0, @recv_timeout) do
      {:ok, data} -> {:ok, data}
      {:error, :timeout} -> {:error, :timeout}
      {:error, reason} -> {:error, reason}
    end
  end

  defp recv_data(socket) do
    case :ssl.recv(socket, 0, @recv_timeout) do
      {:ok, data} -> {:ok, data}
      {:error, :timeout} -> {:error, :timeout}
      {:error, reason} -> {:error, reason}
    end
  end

  defp send_data({:tcp, socket}, data), do: :gen_tcp.send(socket, data)
  defp send_data(socket, data), do: :ssl.send(socket, data)

  defp close_socket({:tcp, socket}), do: :gen_tcp.close(socket)
  defp close_socket(socket), do: :ssl.close(socket)

  defp put_conn(conn), do: Process.put({__MODULE__, :conn}, conn)
  defp get_conn(%__MODULE__{} = conn), do: conn
  defp get_conn(_), do: Process.get({__MODULE__, :conn})
  defp delete_conn, do: Process.delete({__MODULE__, :conn})

  defp normalize_host(host) when is_binary(host), do: String.trim(host)
  defp normalize_host(host), do: host

  defp normalize_text(value) when is_binary(value), do: String.trim(value)
  defp normalize_text(value), do: value

  defp normalize_port(port) when is_integer(port), do: port

  defp normalize_port(port) when is_binary(port) do
    case Integer.parse(String.trim(port)) do
      {value, ""} -> value
      _ -> nil
    end
  end

  defp normalize_port(_), do: nil

  defp require_host(host) when is_binary(host) and host != "", do: {:ok, host}

  defp require_host(_host) do
    {:error, %Error{class: :temporary, code: :invalid_host, message: "SMTP host is invalid"}}
  end

  defp require_port(port) when is_integer(port) and port > 0 and port <= 65_535, do: {:ok, port}

  defp require_port(_port) do
    {:error, %Error{class: :temporary, code: :invalid_port, message: "SMTP port is invalid"}}
  end

  defp connect_failed_error(reason) do
    %Error{
      class: :temporary,
      code: :connect_failed,
      message: "SMTP connect failed: #{inspect_connect_reason(reason)}"
    }
  end

  defp inspect_connect_reason(%_{} = exception), do: Exception.message(exception)
  defp inspect_connect_reason(reason), do: inspect(reason)

  defp ehlo_name(host) when is_binary(host) and host != "", do: host
  defp ehlo_name(_), do: "localhost"

  defp tcp_opts, do: [:binary, active: false, packet: :raw]

  defp ssl_opts(host_charlist) do
    [
      :binary,
      active: false,
      packet: :raw,
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      server_name_indication: host_charlist,
      customize_hostname_check: [
        match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
      ]
    ]
  end
end
