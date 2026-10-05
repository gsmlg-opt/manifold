defmodule Manifold.TestSupport.TLSPeer do
  @moduledoc false

  defstruct [:listener, :listener_kind, :port, :task, :certfile, :keyfile, :tmpdir]

  @type t :: %__MODULE__{}

  @spec certificate_authorities() :: [binary()]
  def certificate_authorities do
    %{cafile: cafile} = certificates()

    cafile
    |> File.read!()
    |> :public_key.pem_decode()
    |> Enum.map(fn {:Certificate, der, :not_encrypted} -> der end)
  end

  @spec server_certificate() :: binary()
  def server_certificate do
    %{certfile: certfile} = certificates()
    [{:Certificate, der, :not_encrypted}] = certfile |> File.read!() |> :public_key.pem_decode()
    der
  end

  @spec certificate_from_pem!(Path.t()) :: binary()
  def certificate_from_pem!(path) do
    [{:Certificate, der, :not_encrypted}] = path |> File.read!() |> :public_key.pem_decode()
    der
  end

  @spec start((:ssl.sslsocket() -> term()), keyword()) :: {:ok, t()}
  def start(handler, options \\ []) when is_function(handler, 1) and is_list(options) do
    :ok = :ssl.start()
    certificates = certificates()
    {certfile, keyfile} = certificate_pair(certificates, Keyword.get(options, :certificate, :rsa))

    tls_options =
      [
        certfile: String.to_charlist(certfile),
        keyfile: String.to_charlist(keyfile),
        versions: [:"tlsv1.3"],
        verify: :verify_none,
        reuseaddr: true,
        active: false,
        mode: :binary,
        packet: :raw
      ]
      |> Keyword.merge(Keyword.get(options, :ssl_options, []))

    {:ok, listener} = :ssl.listen(0, tls_options)

    {:ok, {_address, port}} = :ssl.sockname(listener)

    task =
      Task.async(fn ->
        {:ok, socket} = :ssl.transport_accept(listener, 5_000)

        case :ssl.handshake(socket, 5_000) do
          {:ok, socket} -> handler.(socket)
          {:error, reason} -> {:handshake_error, reason}
        end
      end)

    {:ok,
     %__MODULE__{
       listener: listener,
       listener_kind: :ssl,
       port: port,
       task: task,
       certfile: certfile,
       keyfile: keyfile,
       tmpdir: certificates.tmpdir
     }}
  end

  @spec start_many((:ssl.sslsocket(), pos_integer() -> term()), pos_integer(), keyword()) ::
          {:ok, t()}
  def start_many(handler, count, options \\ [])
      when is_function(handler, 2) and is_integer(count) and count > 0 and is_list(options) do
    :ok = :ssl.start()
    certificates = certificates()
    {certfile, keyfile} = certificate_pair(certificates, Keyword.get(options, :certificate, :rsa))

    tls_options =
      [
        certfile: String.to_charlist(certfile),
        keyfile: String.to_charlist(keyfile),
        versions: [:"tlsv1.3"],
        verify: :verify_none,
        reuseaddr: true,
        active: false,
        mode: :binary,
        packet: :raw
      ]
      |> Keyword.merge(Keyword.get(options, :ssl_options, []))

    {:ok, listener} = :ssl.listen(0, tls_options)
    {:ok, {_address, port}} = :ssl.sockname(listener)

    task =
      Task.async(fn ->
        Enum.map(1..count, fn index ->
          {:ok, socket} = :ssl.transport_accept(listener, 5_000)

          case :ssl.handshake(socket, 5_000) do
            {:ok, socket} -> handler.(socket, index)
            {:error, reason} -> {:handshake_error, reason}
          end
        end)
      end)

    {:ok,
     %__MODULE__{
       listener: listener,
       listener_kind: :ssl,
       port: port,
       task: task,
       certfile: certfile,
       keyfile: keyfile,
       tmpdir: certificates.tmpdir
     }}
  end

  @spec start_starttls((:ssl.sslsocket() -> term())) :: {:ok, t()}
  def start_starttls(handler) when is_function(handler, 1) do
    :ok = :ssl.start()
    %{certfile: certfile, keyfile: keyfile, tmpdir: tmpdir} = certificates()
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, packet: :raw, reuseaddr: true])
    {:ok, {_address, port}} = :inet.sockname(listener)

    task =
      Task.async(fn ->
        {:ok, tcp} = :gen_tcp.accept(listener, 5_000)
        :ok = :gen_tcp.send(tcp, "220 local STARTTLS peer\r\n")
        {:ok, "STARTTLS\r\n"} = :gen_tcp.recv(tcp, 0, 5_000)
        :ok = :gen_tcp.send(tcp, "220 begin TLS\r\n")

        case :ssl.handshake(tcp,
               certfile: String.to_charlist(certfile),
               keyfile: String.to_charlist(keyfile),
               versions: [:"tlsv1.3"],
               verify: :verify_none,
               active: false,
               mode: :binary,
               packet: :raw,
               reuseaddr: true
             ) do
          {:ok, socket} -> handler.(socket)
          {:error, reason} -> {:handshake_error, reason}
        end
      end)

    {:ok,
     %__MODULE__{
       listener: listener,
       listener_kind: :tcp,
       port: port,
       task: task,
       certfile: certfile,
       keyfile: keyfile,
       tmpdir: tmpdir
     }}
  end

  @spec observe_client_hello(pid()) :: {:ok, %{port: :inet.port_number(), task: Task.t()}}
  def observe_client_hello(observer) when is_pid(observer) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, packet: :raw, reuseaddr: true])
    {:ok, {_address, port}} = :inet.sockname(listener)

    task =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 5_000)
        {:ok, bytes} = :gen_tcp.recv(socket, 0, 5_000)
        send(observer, {:client_hello_observed, bytes})
        :ok = :gen_tcp.close(socket)
        :ok = :gen_tcp.close(listener)
      end)

    {:ok, %{port: port, task: task}}
  end

  @spec start_fragmenting_proxy(:inet.port_number(), pid()) ::
          {:ok, %{listener: port(), port: :inet.port_number(), ref: reference(), task: Task.t()}}
  def start_fragmenting_proxy(upstream_port, observer)
      when is_integer(upstream_port) and is_pid(observer) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, packet: :raw, reuseaddr: true])
    {:ok, {_address, port}} = :inet.sockname(listener)
    ref = make_ref()

    task =
      Task.async(fn ->
        with {:ok, downstream} <- :gen_tcp.accept(listener, 5_000),
             {:ok, upstream} <-
               :gen_tcp.connect(
                 ~c"127.0.0.1",
                 upstream_port,
                 [:binary, active: false, packet: :raw],
                 5_000
               ) do
          client_to_server =
            Task.async(fn -> forward(downstream, upstream, :client_to_server, observer, ref) end)

          server_to_client =
            Task.async(fn -> forward(upstream, downstream, :server_to_client, observer, ref) end)

          result = Task.await(client_to_server, :infinity)
          :gen_tcp.close(downstream)
          :gen_tcp.close(upstream)
          _ = Task.shutdown(server_to_client, 1_000)
          result
        end
      end)

    {:ok, %{listener: listener, port: port, ref: ref, task: task}}
  end

  @spec stop_fragmenting_proxy(%{listener: port(), task: Task.t()}) :: term()
  def stop_fragmenting_proxy(%{listener: listener, task: task}) do
    _ = :gen_tcp.close(listener)
    Task.shutdown(task, 6_000)
  end

  defp certificate_pair(%{certfile: certfile, keyfile: keyfile}, :rsa), do: {certfile, keyfile}

  defp certificate_pair(%{ecdsa_certfile: certfile, ecdsa_keyfile: keyfile}, :ecdsa),
    do: {certfile, keyfile}

  defp certificate_pair(%{expired_certfile: certfile, keyfile: keyfile}, :expired),
    do: {certfile, keyfile}

  @spec stop(t()) :: term()
  def stop(%__MODULE__{listener: listener, listener_kind: kind, task: task}) do
    _ = if(kind == :tcp, do: :gen_tcp.close(listener), else: :ssl.close(listener))
    Task.await(task, 6_000)
  end

  @spec client_options() :: keyword()
  def client_options do
    [
      :binary,
      active: false,
      packet: :raw,
      verify: :verify_peer,
      cacerts: certificate_authorities(),
      server_name_indication: ~c"exssl.test",
      customize_hostname_check: [
        match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
      ],
      versions: [:"tlsv1.3"]
    ]
  end

  defp forward(source, destination, direction, observer, ref) do
    case :gen_tcp.recv(source, 0, 5_000) do
      {:ok, bytes} ->
        bytes = coalesce(source, bytes, 8)
        send(observer, {:tls_proxy, ref, direction, bytes})

        case send_fragments(destination, bytes, [1, 2, 3, 5, 8, 13]) do
          :ok -> forward(source, destination, direction, observer, ref)
          :closed -> :closed
          {:error, reason} -> {:error, reason}
        end

      {:error, :closed} ->
        :closed

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp coalesce(_socket, bytes, 0), do: bytes

  defp coalesce(socket, bytes, remaining) do
    case :gen_tcp.recv(socket, 0, 0) do
      {:ok, more} -> coalesce(socket, bytes <> more, remaining - 1)
      {:error, :timeout} -> bytes
      {:error, :closed} -> bytes
      {:error, _reason} -> bytes
    end
  end

  defp send_fragments(socket, bytes, sizes), do: send_fragments(socket, bytes, sizes, sizes)
  defp send_fragments(_socket, <<>>, _sizes, _all_sizes), do: :ok

  defp send_fragments(socket, bytes, [], all_sizes),
    do: send_fragments(socket, bytes, all_sizes, all_sizes)

  defp send_fragments(socket, bytes, [size | sizes], all_sizes) do
    length = min(size, byte_size(bytes))
    <<chunk::binary-size(^length), rest::binary>> = bytes

    case :gen_tcp.send(socket, chunk) do
      :ok -> send_fragments(socket, rest, sizes, all_sizes)
      {:error, :closed} -> :closed
      {:error, reason} -> {:error, reason}
    end
  end

  @spec certificates() :: %{certfile: String.t(), keyfile: String.t(), tmpdir: String.t()}
  def certificates do
    key = {__MODULE__, :certificates}

    case :persistent_term.get(key, nil) do
      nil ->
        suffix = :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)
        tmpdir = Path.join(System.tmp_dir!(), "ex-ssl-test-#{suffix}")
        File.mkdir_p!(tmpdir)
        cafile = Path.join(tmpdir, "ca.pem")
        cakeyfile = Path.join(tmpdir, "ca-key.pem")
        certfile = Path.join(tmpdir, "server.pem")
        keyfile = Path.join(tmpdir, "server-key.pem")
        ecdsa_certfile = Path.join(tmpdir, "server-ecdsa.pem")
        ecdsa_keyfile = Path.join(tmpdir, "server-ecdsa-key.pem")
        requestfile = Path.join(tmpdir, "server.csr")
        ecdsa_requestfile = Path.join(tmpdir, "server-ecdsa.csr")
        expired_certfile = Path.join(tmpdir, "server-expired.pem")
        ca_config = Path.join(tmpdir, "ca.cnf")
        indexfile = Path.join(tmpdir, "index.txt")
        serialfile = Path.join(tmpdir, "serial")
        extensions = Path.join(tmpdir, "server.ext")

        {_, 0} =
          System.cmd(
            "openssl",
            [
              "req",
              "-x509",
              "-newkey",
              "rsa:2048",
              "-nodes",
              "-keyout",
              cakeyfile,
              "-out",
              cafile,
              "-subj",
              "/CN=ex-ssl test CA",
              "-addext",
              "basicConstraints=critical,CA:TRUE",
              "-addext",
              "keyUsage=critical,keyCertSign,cRLSign",
              "-days",
              "2"
            ],
            stderr_to_stdout: true
          )

        {_, 0} =
          System.cmd(
            "openssl",
            [
              "req",
              "-newkey",
              "rsa:2048",
              "-nodes",
              "-keyout",
              keyfile,
              "-out",
              requestfile,
              "-subj",
              "/CN=exssl.test"
            ],
            stderr_to_stdout: true
          )

        File.write!(indexfile, "")
        File.write!(serialfile, "01\n")

        File.write!(
          ca_config,
          """
          [ ca ]
          default_ca = local_ca
          [ local_ca ]
          database = #{indexfile}
          serial = #{serialfile}
          new_certs_dir = #{tmpdir}
          certificate = #{cafile}
          private_key = #{cakeyfile}
          default_md = sha256
          policy = policy_any
          x509_extensions = server_extensions
          [ policy_any ]
          commonName = supplied
          [ server_extensions ]
          subjectAltName = DNS:exssl.test
          basicConstraints = critical,CA:FALSE
          keyUsage = critical,digitalSignature,keyEncipherment
          extendedKeyUsage = serverAuth
          """
        )

        {_, 0} =
          System.cmd(
            "openssl",
            [
              "ca",
              "-batch",
              "-config",
              ca_config,
              "-in",
              requestfile,
              "-out",
              expired_certfile,
              "-startdate",
              "20200101000000Z",
              "-enddate",
              "20200102000000Z"
            ],
            stderr_to_stdout: true
          )

        File.write!(
          extensions,
          "subjectAltName=DNS:exssl.test\nbasicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n"
        )

        {_, 0} =
          System.cmd(
            "openssl",
            [
              "x509",
              "-req",
              "-in",
              requestfile,
              "-CA",
              cafile,
              "-CAkey",
              cakeyfile,
              "-CAcreateserial",
              "-out",
              certfile,
              "-days",
              "2",
              "-extfile",
              extensions
            ],
            stderr_to_stdout: true
          )

        {_, 0} =
          System.cmd(
            "openssl",
            [
              "ecparam",
              "-name",
              "prime256v1",
              "-genkey",
              "-noout",
              "-out",
              ecdsa_keyfile
            ],
            stderr_to_stdout: true
          )

        {_, 0} =
          System.cmd(
            "openssl",
            [
              "req",
              "-new",
              "-key",
              ecdsa_keyfile,
              "-out",
              ecdsa_requestfile,
              "-subj",
              "/CN=exssl.test"
            ],
            stderr_to_stdout: true
          )

        {_, 0} =
          System.cmd(
            "openssl",
            [
              "x509",
              "-req",
              "-in",
              ecdsa_requestfile,
              "-CA",
              cafile,
              "-CAkey",
              cakeyfile,
              "-CAcreateserial",
              "-out",
              ecdsa_certfile,
              "-days",
              "2",
              "-extfile",
              extensions
            ],
            stderr_to_stdout: true
          )

        certs = %{
          certfile: certfile,
          cafile: cafile,
          keyfile: keyfile,
          ecdsa_certfile: ecdsa_certfile,
          ecdsa_keyfile: ecdsa_keyfile,
          expired_certfile: expired_certfile,
          tmpdir: tmpdir
        }

        :persistent_term.put(key, certs)
        certs

      certs ->
        certs
    end
  end
end
