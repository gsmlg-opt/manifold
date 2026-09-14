defmodule Manifold.Connectors.TLS do
  @moduledoc """
  Explicit TLS selection for outbound IMAP, SMTP submission and EAS.

  OTP is the default. A connection's `:tls` setting overrides the account entry
  in `:manifold_connectors, :tls_backends`. Selection is stored in the returned
  opaque socket and never changed by send/receive/close. There is no fallback.
  """
  import Kernel, except: [send: 2]

  defmodule Config do
    @moduledoc false
    @derive {Inspect, only: [:backend]}
    defstruct backend: :otp, options: []
    @type t :: %__MODULE__{backend: :otp | :ex_ssl, options: keyword()}
  end

  defmodule Socket do
    @moduledoc false
    @derive {Inspect, only: [:backend]}
    @enforce_keys [:backend, :socket]
    defstruct [:backend, :socket]
    @opaque t :: %__MODULE__{backend: :otp | :ex_ssl, socket: term()}
  end

  @option_keys [
    :cacerts,
    :cacertfile,
    :server_name_indication,
    :customize_hostname_check,
    :versions,
    :ex_ssl
  ]
  @write_chunk_bytes 1_048_576

  @spec config(map()) :: {:ok, Config.t()} | {:error, {:options, atom()}}
  def config(settings) when is_map(settings) do
    accounts = Application.get_env(:manifold_connectors, :tls_backends, %{})

    with true <- is_map(accounts),
         selected <- Map.get(settings, :tls, Map.get(accounts, settings[:account_id], [])),
         true <- unique_keyword?(selected),
         true <- Enum.all?(Keyword.keys(selected), &(&1 in [:backend, :options])),
         backend <- Keyword.get(selected, :backend, :otp),
         true <- backend in [:otp, :ex_ssl],
         options <- Keyword.get(selected, :options, []),
         true <- unique_keyword?(options),
         true <- Enum.all?(Keyword.keys(options), &(&1 in @option_keys)),
         true <- backend == :ex_ssl or not Keyword.has_key?(options, :ex_ssl) do
      {:ok, %Config{backend: backend, options: options}}
    else
      _ -> {:error, {:options, :invalid_tls_backend_configuration}}
    end
  end

  def config(_), do: {:error, {:options, :invalid_tls_backend_configuration}}

  @spec connect(term(), :inet.port_number(), list(), timeout(), Config.t()) ::
          {:ok, Socket.t()} | {:error, term()}
  def connect(host, port, options, timeout, %Config{backend: backend} = config)
      when backend in [:otp, :ex_ssl] do
    backend_module(backend).connect(host, port, merge_options(options, config), timeout)
    |> wrap(backend)
  end

  @spec upgrade(:gen_tcp.socket(), list(), timeout(), Config.t()) ::
          {:ok, Socket.t()} | {:error, term()}
  def upgrade(tcp, options, timeout, %Config{backend: backend} = config)
      when backend in [:otp, :ex_ssl] do
    result =
      with :ok <- upgrade_boundary(tcp) do
        backend_module(backend).connect(tcp, merge_options(options, config), timeout)
        |> wrap(backend)
      end

    if match?({:error, _}, result), do: close_owned_tcp(tcp)
    result
  rescue
    _error ->
      close_owned_tcp(tcp)
      {:error, :badarg}
  catch
    :exit, _reason ->
      close_owned_tcp(tcp)
      {:error, :closed}
  end

  defp upgrade_boundary(tcp) when is_port(tcp) do
    with {:connected, owner} when owner == self() <- Port.info(tcp, :connected),
         {:ok, options} <- :inet.getopts(tcp, [:active, :packet, :mode]),
         true <-
           options[:active] == false and options[:packet] == 0 and options[:mode] == :binary,
         {:messages, messages} <- Process.info(self(), :messages),
         false <- Enum.any?(messages, &tcp_message?(&1, tcp)) do
      case :gen_tcp.recv(tcp, 0, 0) do
        {:error, :timeout} -> :ok
        {:ok, _bytes} -> {:error, :pending_plaintext}
        {:error, _} = error -> error
      end
    else
      {:connected, _other_owner} -> {:error, :not_owner}
      nil -> {:error, :closed}
      false -> {:error, :einval}
      true -> {:error, :pending_plaintext}
      {:error, _} = error -> error
    end
  end

  defp upgrade_boundary(_tcp), do: {:error, :badarg}
  defp tcp_message?({:tcp, socket, _}, tcp), do: socket == tcp
  defp tcp_message?({:tcp_closed, socket}, tcp), do: socket == tcp
  defp tcp_message?({:tcp_error, socket, _}, tcp), do: socket == tcp
  defp tcp_message?(_, _tcp), do: false

  @spec send(Socket.t(), iodata()) :: :ok | {:error, term()}
  def send(%Socket{backend: :otp, socket: socket}, data), do: :ssl.send(socket, data)

  def send(%Socket{backend: :ex_ssl, socket: socket}, data) do
    # Admit each bounded library write once. Never retry a failed/ambiguous chunk.
    if :erlang.iolist_size(data) <= @write_chunk_bytes,
      do: SSL.send(socket, data),
      else: send_chunks(socket, IO.iodata_to_binary(data))
  rescue
    ArgumentError -> {:error, :badarg}
  end

  @spec recv(Socket.t(), non_neg_integer(), timeout()) :: {:ok, binary()} | {:error, term()}
  def recv(%Socket{backend: backend, socket: socket}, length, timeout),
    do: backend_module(backend).recv(socket, length, timeout)

  @spec close(Socket.t()) :: :ok | {:error, term()}
  def close(%Socket{backend: backend, socket: socket}), do: backend_module(backend).close(socket)

  defp send_chunks(_socket, <<>>), do: :ok

  defp send_chunks(socket, bytes) when byte_size(bytes) <= @write_chunk_bytes,
    do: SSL.send(socket, bytes)

  defp send_chunks(socket, <<chunk::binary-size(@write_chunk_bytes), rest::binary>>) do
    with :ok <- SSL.send(socket, chunk), do: send_chunks(socket, rest)
  end

  defp merge_options(options, %Config{options: overrides}) do
    replaced = Keyword.keys(overrides)
    replaced = if :cacertfile in replaced, do: [:cacerts | replaced], else: replaced

    Enum.reject(options, fn
      {key, _value} -> key in replaced
      _ -> false
    end) ++ overrides
  end

  defp wrap({:ok, socket}, backend), do: {:ok, %Socket{backend: backend, socket: socket}}
  defp wrap({:error, _} = error, _backend), do: error
  defp backend_module(:otp), do: :ssl
  defp backend_module(:ex_ssl), do: SSL

  defp close_owned_tcp(tcp) when is_port(tcp) do
    case Port.info(tcp, :connected) do
      {:connected, owner} when owner == self() -> :gen_tcp.close(tcp)
      _ -> :ok
    end
  end

  defp close_owned_tcp(_), do: :ok

  defp unique_keyword?(value) do
    Keyword.keyword?(value) and
      length(Keyword.keys(value)) == length(Enum.uniq(Keyword.keys(value)))
  end
end
