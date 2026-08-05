defmodule Manifold.Connectors.IMAP.Client do
  @moduledoc false

  @behaviour Manifold.Connectors.IMAP.Transport

  alias Manifold.Connectors.Provider.Error

  defstruct [:socket, :tag_seq, :buffer]

  @connect_timeout 15_000
  @recv_timeout 30_000

  @impl true
  def connect(settings) when is_map(settings) do
    host = Map.fetch!(settings, :host)
    port = Map.fetch!(settings, :port)
    tls_mode = Map.fetch!(settings, :tls_mode)
    username = Map.fetch!(settings, :username)
    password = Map.fetch!(settings, :password)

    with {:ok, conn} <- open_and_greet(host, port, tls_mode),
         {:ok, conn} <-
           command(conn, "LOGIN #{quote_string(username)} #{quote_string(password)}", auth: true) do
      put_conn(conn)
      {:ok, conn}
    else
      {:error, %Error{} = error} ->
        {:error, error}

      {:error, :timeout} ->
        {:error, %Error{class: :temporary, code: :timeout, message: "IMAP connection timed out"}}

      {:error, reason} ->
        {:error,
         %Error{
           class: :temporary,
           code: :connect_failed,
           message: "IMAP connect failed: #{inspect(reason)}"
         }}
    end
  end

  @impl true
  def select(conn, mailbox_path) when is_binary(mailbox_path) do
    conn = get_conn(conn)

    case command(conn, "SELECT #{quote_mailbox(mailbox_path)}") do
      {:ok, conn, lines} ->
        put_conn(conn)

        case parse_uidvalidity(lines) do
          {:ok, uidvalidity} ->
            {:ok, %{uidvalidity: uidvalidity, uidnext: parse_uidnext(lines)}}

          {:error, _} = error ->
            error
        end

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  @impl true
  def uid_search(conn, query) when is_binary(query) do
    conn = get_conn(conn)

    case command(conn, "UID SEARCH #{query}") do
      {:ok, conn, lines} ->
        put_conn(conn)
        parse_search_response(lines)

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  @impl true
  def uid_fetch_rfc822(conn, uid) when is_integer(uid) do
    conn = get_conn(conn)

    case command(conn, "UID FETCH #{uid} (RFC822)") do
      {:ok, conn, lines} ->
        put_conn(conn)
        extract_rfc822(lines)

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  @impl true
  def logout(conn) do
    conn = get_conn(conn)
    _ = command(conn, "LOGOUT")
    close_socket(conn.socket)
    delete_conn()
    :ok
  end

  # --- Pure parsers (unit-tested) ---

  @doc false
  def parse_search_response(lines) when is_list(lines) do
    uids =
      lines
      |> Enum.flat_map(fn line ->
        case Regex.run(~r/^\* SEARCH(?: (.*))?$/i, String.trim(line)) do
          [_, rest] when is_binary(rest) and rest != "" ->
            rest
            |> String.split(~r/\s+/, trim: true)
            |> Enum.map(&String.to_integer/1)

          _ ->
            []
        end
      end)

    {:ok, uids}
  end

  @doc false
  def parse_uidvalidity(lines) when is_list(lines) do
    Enum.find_value(lines, fn line ->
      case Regex.run(~r/\* OK \[UIDVALIDITY (\d+)\]/i, line) do
        [_, value] -> {:ok, String.to_integer(value)}
        nil -> nil
      end
    end) ||
      {:error,
       %Error{class: :temporary, code: :uidvalidity_missing, message: "UIDVALIDITY not found"}}
  end

  @doc false
  def parse_uidnext(lines) when is_list(lines) do
    Enum.find_value(lines, fn line ->
      case Regex.run(~r/\* OK \[UIDNEXT (\d+)\]/i, line) do
        [_, value] -> String.to_integer(value)
        nil -> nil
      end
    end)
  end

  @doc false
  def extract_rfc822(lines) when is_list(lines) do
    blob = Enum.join(lines, "\r\n")

    case Regex.run(~r/\{(\d+)\}\r?\n([\s\S]*)/m, blob) do
      [_, size_str, rest] ->
        size = String.to_integer(size_str)

        if byte_size(rest) >= size do
          <<rfc822::binary-size(^size), _::binary>> = rest
          {:ok, rfc822}
        else
          {:error,
           %Error{class: :temporary, code: :fetch_parse_failed, message: "RFC822 size mismatch"}}
        end

      nil ->
        {:error,
         %Error{class: :temporary, code: :fetch_parse_failed, message: "RFC822 parse failed"}}
    end
  end

  # --- Socket / protocol ---

  defp open_and_greet(host, port, "ssl") do
    host_charlist = String.to_charlist(host)

    with {:ok, socket} <-
           :ssl.connect(host_charlist, port, ssl_opts(host_charlist), @connect_timeout) do
      read_greeting(%__MODULE__{socket: socket, tag_seq: 0, buffer: ""})
    end
  end

  defp open_and_greet(host, port, "starttls") do
    host_charlist = String.to_charlist(host)

    with {:ok, tcp} <- :gen_tcp.connect(host_charlist, port, tcp_opts(), @connect_timeout),
         conn <- %__MODULE__{socket: {:tcp, tcp}, tag_seq: 0, buffer: ""},
         {:ok, conn} <- read_greeting(conn),
         {:ok, conn, _lines} <- command(conn, "STARTTLS"),
         {:tcp, tcp} <- conn.socket,
         {:ok, ssl} <- :ssl.connect(tcp, ssl_opts(host_charlist), @connect_timeout) do
      {:ok, %{conn | socket: ssl, buffer: ""}}
    end
  end

  defp open_and_greet(_host, _port, tls_mode) do
    {:error, {:unsupported_tls_mode, tls_mode}}
  end

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

  defp read_greeting(conn) do
    case recv_line(conn) do
      {:ok, conn, line} ->
        if String.starts_with?(line, "* OK") or String.starts_with?(line, "* PREAUTH") do
          {:ok, conn}
        else
          close_socket(conn.socket)

          {:error,
           %Error{class: :temporary, code: :bad_greeting, message: "Unexpected IMAP greeting"}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp command(conn, text, opts \\ []) do
    auth? = Keyword.get(opts, :auth, false)
    {tag, conn} = next_tag(conn)
    payload = tag <> " " <> text <> "\r\n"

    case send_data(conn.socket, payload) do
      :ok ->
        collect_tagged(conn, tag, [], auth?)

      {:error, reason} ->
        {:error,
         %Error{
           class: :temporary,
           code: :send_failed,
           message: "IMAP send failed: #{inspect(reason)}"
         }}
    end
  end

  defp collect_tagged(conn, tag, acc, auth?) do
    case recv_line(conn) do
      {:ok, conn, line} ->
        cond do
          String.starts_with?(line, tag <> " OK") ->
            result_lines = Enum.reverse(acc)
            if auth?, do: {:ok, conn}, else: {:ok, conn, result_lines}

          String.starts_with?(line, tag <> " NO") ->
            {:error, classify_no(line, auth?)}

          String.starts_with?(line, tag <> " BAD") ->
            {:error, %Error{class: :permanent, code: :bad_command, message: "IMAP BAD: #{line}"}}

          true ->
            case Regex.run(~r/\{(\d+)\}$/, line) do
              [_, size_str] ->
                size = String.to_integer(size_str)

                case recv_bytes(conn, size) do
                  {:ok, conn, bytes} ->
                    collect_tagged(conn, tag, [line <> "\n" <> bytes | acc], auth?)

                  {:error, :timeout} ->
                    {:error,
                     %Error{class: :temporary, code: :timeout, message: "IMAP receive timed out"}}

                  {:error, reason} ->
                    {:error,
                     %Error{
                       class: :temporary,
                       code: :recv_failed,
                       message: "IMAP receive failed: #{inspect(reason)}"
                     }}
                end

              nil ->
                collect_tagged(conn, tag, [line | acc], auth?)
            end
        end

      {:error, :timeout} ->
        {:error, %Error{class: :temporary, code: :timeout, message: "IMAP receive timed out"}}

      {:error, reason} ->
        {:error,
         %Error{
           class: :temporary,
           code: :recv_failed,
           message: "IMAP receive failed: #{inspect(reason)}"
         }}
    end
  end

  defp classify_no(_line, true) do
    %Error{class: :reconnect, code: :auth_failed, message: "IMAP authentication failed"}
  end

  defp classify_no(line, false) do
    %Error{class: :temporary, code: :command_no, message: "IMAP NO: #{line}"}
  end

  defp next_tag(%__MODULE__{tag_seq: seq} = conn) do
    tag = "A" <> Integer.to_string(seq + 1)
    {tag, %{conn | tag_seq: seq + 1}}
  end

  defp recv_line(%__MODULE__{buffer: buffer} = conn) do
    case :binary.split(buffer, "\r\n") do
      [line, rest] ->
        {:ok, %{conn | buffer: rest}, line}

      [_] ->
        case recv_data(conn.socket) do
          {:ok, data} -> recv_line(%{conn | buffer: buffer <> data})
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp recv_bytes(%__MODULE__{buffer: buffer} = conn, size) when is_integer(size) do
    if byte_size(buffer) >= size do
      <<bytes::binary-size(size), rest::binary>> = buffer
      {:ok, %{conn | buffer: rest}, bytes}
    else
      case recv_data(conn.socket) do
        {:ok, data} -> recv_bytes(%{conn | buffer: buffer <> data}, size)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp send_data({:tcp, socket}, data), do: :gen_tcp.send(socket, data)
  defp send_data(socket, data), do: :ssl.send(socket, data)

  defp recv_data({:tcp, socket}) do
    case :gen_tcp.recv(socket, 0, @recv_timeout) do
      {:ok, data} -> {:ok, data}
      {:error, reason} -> {:error, reason}
    end
  end

  defp recv_data(socket) do
    case :ssl.recv(socket, 0, @recv_timeout) do
      {:ok, data} -> {:ok, data}
      {:error, reason} -> {:error, reason}
    end
  end

  defp close_socket({:tcp, socket}), do: :gen_tcp.close(socket)
  defp close_socket(socket), do: :ssl.close(socket)

  defp quote_string(value) when is_binary(value) do
    "\"" <> String.replace(value, ["\\", "\""], fn c -> "\\" <> c end) <> "\""
  end

  defp quote_mailbox("INBOX"), do: "INBOX"
  defp quote_mailbox(path), do: quote_string(path)

  defp put_conn(conn), do: Process.put({__MODULE__, :conn}, conn)
  defp get_conn(%__MODULE__{} = conn), do: Process.get({__MODULE__, :conn}, conn)
  defp get_conn(other), do: Process.get({__MODULE__, :conn}, other)
  defp delete_conn, do: Process.delete({__MODULE__, :conn})
end
