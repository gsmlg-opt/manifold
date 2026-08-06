defmodule Manifold.Connectors.IMAP.Client do
  @moduledoc false

  @behaviour Manifold.Connectors.IMAP.Transport

  alias Manifold.Connectors.Provider.Error

  defstruct [:socket, :tag_seq, :buffer]

  @connect_timeout 15_000
  @recv_timeout 30_000

  @impl true
  def connect(settings) when is_map(settings) do
    host = settings |> Map.fetch!(:host) |> normalize_host()
    port = normalize_port(Map.fetch!(settings, :port))
    tls_mode = Map.fetch!(settings, :tls_mode)
    username = settings |> Map.fetch!(:username) |> normalize_text()
    password = Map.fetch!(settings, :password)
    base_meta = imap_base_meta(settings, host, port, tls_mode)
    Process.put({__MODULE__, :emit_activity}, Map.get(settings, :emit_activity, true))

    connect_start = System.monotonic_time()

    with {:ok, host} <- require_host(host),
         {:ok, port} <- require_port(port),
         {:ok, conn} <- open_and_greet_safe(host, port, tls_mode) do
      emit_imap([:manifold, :connectors, :imap, :connect, :stop], connect_start, base_meta, :ok)
      Process.put({__MODULE__, :activity_meta}, base_meta)

      auth_start = System.monotonic_time()
      auth_meta = Map.put(base_meta, :username, username)

      case command(conn, "LOGIN #{quote_string(username)} #{quote_string(password)}", auth: true) do
        {:ok, conn} ->
          emit_imap([:manifold, :connectors, :imap, :auth, :stop], auth_start, auth_meta, :ok)
          put_conn(conn)
          {:ok, conn}

        {:error, %Error{} = error} ->
          emit_imap([:manifold, :connectors, :imap, :auth, :stop], auth_start, auth_meta, error)
          {:error, error}
      end
    else
      {:error, %Error{} = error} ->
        emit_imap(
          [:manifold, :connectors, :imap, :connect, :stop],
          connect_start,
          base_meta,
          error
        )

        {:error, error}

      {:error, :timeout} ->
        error = %Error{class: :temporary, code: :timeout, message: "IMAP connection timed out"}

        emit_imap(
          [:manifold, :connectors, :imap, :connect, :stop],
          connect_start,
          base_meta,
          error
        )

        {:error, error}

      {:error, reason} ->
        error = connect_failed_error(reason)

        emit_imap(
          [:manifold, :connectors, :imap, :connect, :stop],
          connect_start,
          base_meta,
          error
        )

        {:error, error}
    end
  end

  @impl true
  def select(conn, mailbox_path) when is_binary(mailbox_path) do
    conn = get_conn(conn)
    start = System.monotonic_time()
    meta = Map.put(imap_conn_meta(conn), :mailbox_path, mailbox_path)

    case command(conn, "SELECT #{quote_mailbox(mailbox_path)}") do
      {:ok, conn, lines} ->
        put_conn(conn)

        case parse_uidvalidity(lines) do
          {:ok, uidvalidity} ->
            emit_imap(
              [:manifold, :connectors, :imap, :select, :stop],
              start,
              Map.put(meta, :uidvalidity, uidvalidity),
              :ok
            )

            {:ok, %{uidvalidity: uidvalidity, uidnext: parse_uidnext(lines)}}

          {:error, %Error{} = error} ->
            emit_imap([:manifold, :connectors, :imap, :select, :stop], start, meta, error)
            {:error, error}
        end

      {:error, %Error{} = error} ->
        emit_imap([:manifold, :connectors, :imap, :select, :stop], start, meta, error)
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
  def uid_fetch_flags(_conn, []), do: {:ok, %{}}

  def uid_fetch_flags(conn, uids) when is_list(uids) do
    conn = get_conn(conn)
    set = Enum.map_join(uids, ",", &Integer.to_string/1)

    case command(conn, "UID FETCH #{set} (FLAGS INTERNALDATE)") do
      {:ok, conn, lines} ->
        put_conn(conn)
        parse_flags_response(lines)

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  @impl true
  def uid_store_flags(conn, uid, op, flags)
      when is_integer(uid) and op in [:add, :remove] and is_list(flags) do
    conn = get_conn(conn)

    case command(conn, store_flags_command(uid, op, flags)) do
      {:ok, conn, _lines} ->
        put_conn(conn)
        :ok

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
    Process.delete({__MODULE__, :activity_meta})
    Process.delete({__MODULE__, :emit_activity})
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
  def parse_flags_response(lines) when is_list(lines) do
    meta_by_uid =
      Enum.reduce(lines, %{}, fn line, acc ->
        case parse_fetch_flags_line(String.trim(line)) do
          {:ok, uid, meta} -> Map.put(acc, uid, meta)
          :error -> acc
        end
      end)

    {:ok, meta_by_uid}
  end

  @doc false
  def parse_internal_date(nil), do: {:ok, nil}

  def parse_internal_date(value) when is_binary(value) do
    value = value |> String.trim() |> String.trim("\"")

    case Regex.run(
           ~r/^(\d{1,2})-([A-Za-z]{3})-(\d{4}) (\d{2}):(\d{2}):(\d{2}) ([+-]\d{4})$/,
           value
         ) do
      [_, day, mon, year, hour, minute, second, offset] ->
        with {:ok, month} <- imap_month(mon),
             {:ok, naive} <-
               NaiveDateTime.new(
                 String.to_integer(year),
                 month,
                 String.to_integer(day),
                 String.to_integer(hour),
                 String.to_integer(minute),
                 String.to_integer(second)
               ) do
          utc =
            naive
            |> DateTime.from_naive!("Etc/UTC")
            |> DateTime.add(-offset_seconds(offset), :second)
            |> Map.put(:microsecond, {0, 6})

          {:ok, utc}
        else
          _ -> {:ok, nil}
        end

      nil ->
        {:ok, nil}
    end
  end

  def parse_internal_date(_value), do: {:ok, nil}

  @doc false
  def seen?(flags) when is_list(flags) do
    Enum.any?(flags, fn flag -> String.downcase(flag) == "\\seen" end)
  end

  @doc false
  def store_flags_command(uid, op, flags)
      when is_integer(uid) and op in [:add, :remove] and is_list(flags) do
    prefix = if(op == :add, do: "+FLAGS", else: "-FLAGS")
    "UID STORE #{uid} #{prefix} (#{Enum.join(flags, " ")})"
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

  defp parse_fetch_flags_line(line) do
    with [_ | _] <- Regex.run(~r/^\* \d+ FETCH \(/i, line),
         [_, uid_str] <- Regex.run(~r/\bUID (\d+)\b/i, line) do
      flags =
        case Regex.run(~r/\bFLAGS \(([^)]*)\)/i, line) do
          [_, flags_body] ->
            flags_body
            |> String.split(~r/\s+/, trim: true)
            |> Enum.reject(&(&1 == ""))

          nil ->
            []
        end

      received_at =
        case Regex.run(~r/\bINTERNALDATE "([^"]+)"/i, line) do
          [_, date] ->
            case parse_internal_date(date) do
              {:ok, %DateTime{} = dt} -> dt
              _ -> nil
            end

          nil ->
            nil
        end

      {:ok, String.to_integer(uid_str), %{flags: flags, received_at: received_at}}
    else
      _ -> :error
    end
  end

  defp imap_month(mon) do
    Map.fetch(
      %{
        "jan" => 1,
        "feb" => 2,
        "mar" => 3,
        "apr" => 4,
        "may" => 5,
        "jun" => 6,
        "jul" => 7,
        "aug" => 8,
        "sep" => 9,
        "oct" => 10,
        "nov" => 11,
        "dec" => 12
      },
      String.downcase(mon)
    )
  end

  defp offset_seconds(<<sign::binary-size(1), hh::binary-size(2), mm::binary-size(2)>>) do
    hours = String.to_integer(hh)
    minutes = String.to_integer(mm)
    seconds = hours * 3600 + minutes * 60
    if sign == "-", do: -seconds, else: seconds
  end

  # --- Socket / protocol ---

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

    :exit, {:function_clause, _} = reason ->
      {:error, connect_failed_error(reason)}
  end

  # Exposed for unit tests covering ArgumentError → {:error, _} conversion.
  @doc false
  def open_and_greet_for_test(host, port, tls_mode), do: open_and_greet_safe(host, port, tls_mode)

  defp open_and_greet(host, port, tls_mode)
       when tls_mode in ["ssl", "tls"] and is_binary(host) and is_integer(port) do
    host_charlist = String.to_charlist(host)

    with {:ok, socket} <-
           :ssl.connect(host_charlist, port, ssl_opts(host_charlist), @connect_timeout) do
      read_greeting(%__MODULE__{socket: socket, tag_seq: 0, buffer: ""})
    end
  end

  defp open_and_greet(host, port, "starttls") when is_binary(host) and is_integer(port) do
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
    {:error, %Error{class: :temporary, code: :invalid_host, message: "IMAP host is invalid"}}
  end

  defp require_port(port) when is_integer(port) and port > 0 and port <= 65_535, do: {:ok, port}

  defp require_port(_port) do
    {:error, %Error{class: :temporary, code: :invalid_port, message: "IMAP port is invalid"}}
  end

  defp connect_failed_error(reason) do
    %Error{
      class: :temporary,
      code: :connect_failed,
      message: "IMAP connect failed: #{inspect_connect_reason(reason)}"
    }
  end

  defp inspect_connect_reason(%_{} = exception), do: Exception.message(exception)
  defp inspect_connect_reason(reason), do: inspect(reason)

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
      <<bytes::binary-size(^size), rest::binary>> = buffer
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

  defp imap_base_meta(settings, host, port, tls_mode) do
    %{host: host, port: port, tls_mode: tls_mode, provider: "imap"}
    |> then(fn m ->
      case Map.get(settings, :account_id) do
        id when is_binary(id) -> Map.put(m, :account_id, id)
        _ -> m
      end
    end)
  end

  defp imap_conn_meta(_conn) do
    Process.get({__MODULE__, :activity_meta}, %{provider: "imap"})
  end

  defp emit_imap(event, start, meta, :ok) do
    if Process.get({__MODULE__, :emit_activity}, true) != false do
      :telemetry.execute(event, %{duration_ms: duration_ms(start)}, Map.put(meta, :result, :ok))
    end
  end

  defp emit_imap(event, start, meta, %Error{} = error) do
    if Process.get({__MODULE__, :emit_activity}, true) != false do
      :telemetry.execute(
        event,
        %{duration_ms: duration_ms(start)},
        meta
        |> Map.put(:result, :error)
        |> Map.put(:error_code, error.code)
        |> Map.put(:error_message, error.message)
      )
    end
  end

  defp duration_ms(start) do
    System.convert_time_unit(System.monotonic_time() - start, :native, :millisecond)
  end
end
