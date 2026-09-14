defmodule Manifold.Connectors.TLSTest do
  use ExUnit.Case, async: false

  alias Manifold.Connectors.TLS
  alias Manifold.TestSupport.TLSPeer, as: Peer

  Code.require_file("../../support/tls_peer.exs", __DIR__)

  test "OTP is the default and account selection is explicit and validated" do
    previous = Application.get_env(:manifold_connectors, :tls_backends)
    on_exit(fn -> restore_config(previous) end)

    Application.put_env(:manifold_connectors, :tls_backends, %{
      "controlled" => [backend: :ex_ssl]
    })

    assert {:ok, %{backend: :otp}} = TLS.config(%{})
    assert {:ok, %{backend: :ex_ssl}} = TLS.config(%{account_id: "controlled"})
    assert {:ok, %{backend: :otp}} = TLS.config(%{account_id: "other"})
    assert {:ok, %{backend: :otp}} = TLS.config(%{account_id: "controlled", tls: [backend: :otp]})
    assert {:error, {:options, _}} = TLS.config(%{tls: [backend: :unknown]})
    assert {:error, {:options, _}} = TLS.config(%{tls: [backend: :ex_ssl, fallback: :otp]})
    assert {:error, {:options, _}} = TLS.config(%{tls: [options: [verify: :verify_none]]})
  end

  for backend <- [:otp, :ex_ssl] do
    test "#{backend} handle retains its selected backend and sends a payload over 1 MiB" do
      previous = Application.get_env(:manifold_connectors, :tls_backends)
      on_exit(fn -> restore_config(previous) end)

      Application.put_env(:manifold_connectors, :tls_backends, %{
        "retained" => [backend: unquote(backend)]
      })

      payload = :binary.copy("large message\r\n", 80_000)
      digest = :crypto.hash(:sha256, payload)

      {:ok, peer} =
        Peer.start(fn socket ->
          assert {:ok, received} = :ssl.recv(socket, byte_size(payload), 5_000)
          assert received == payload
          :ok = :ssl.send(socket, :crypto.hash(:sha256, received))
          :ok
        end)

      {:ok, config} = TLS.config(%{account_id: "retained"})

      assert {:ok, socket} =
               TLS.connect(~c"127.0.0.1", peer.port, Peer.client_options(), 5_000, config)

      assert socket.backend == unquote(backend)
      replacement = if unquote(backend) == :otp, do: :ex_ssl, else: :otp

      Application.put_env(:manifold_connectors, :tls_backends, %{
        "retained" => [backend: replacement]
      })

      assert :ok = TLS.send(socket, [payload, []])
      assert {:ok, ^digest} = TLS.recv(socket, 32, 5_000)
      assert :ok = TLS.close(socket)
      assert :ok = Peer.stop(peer)
    end
  end

  test "cacertfile explicitly replaces the default CA list and option inspection is redacted" do
    {:ok, peer} = Peer.start(fn socket -> :ssl.send(socket, "ok") end)
    certificates = Peer.certificates()

    {:ok, config} =
      TLS.config(%{tls: [backend: :ex_ssl, options: [cacertfile: certificates.cafile]]})

    base = [
      :binary,
      verify: :verify_peer,
      active: false,
      packet: :raw,
      cacerts: :public_key.cacerts_get(),
      server_name_indication: ~c"exssl.test"
    ]

    assert {:ok, socket} = TLS.connect(~c"127.0.0.1", peer.port, base, 5_000, config)
    assert {:ok, "ok"} = TLS.recv(socket, 2, 5_000)
    refute inspect(config) =~ certificates.cafile
    assert :ok = TLS.close(socket)
    assert :ok = Peer.stop(peer)
  end

  test "the backend boundary preserves the library's non-owner upgrade rejection" do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, {_, port}} = :inet.sockname(listener)
    {:ok, tcp} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 1_000)
    {:ok, server} = :gen_tcp.accept(listener, 1_000)
    {:ok, config} = TLS.config(%{tls: [backend: :ex_ssl]})

    task = Task.async(fn -> TLS.upgrade(tcp, Peer.client_options(), 1_000, config) end)
    assert {:error, :not_owner} = Task.await(task)
    assert :ok = :gen_tcp.send(tcp, "still owned")
    assert {:ok, "still owned"} = :gen_tcp.recv(server, 0, 1_000)
    Enum.each([tcp, server, listener], &:gen_tcp.close/1)
  end

  test "both upgrades reject already-delivered plaintext without sending a ClientHello" do
    for backend <- [:otp, :ex_ssl] do
      {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
      {:ok, {_, port}} = :inet.sockname(listener)
      {:ok, tcp} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: :once], 1_000)
      {:ok, server} = :gen_tcp.accept(listener, 1_000)
      :ok = :gen_tcp.send(server, "unexpected plaintext")
      assert_receive {:tcp, ^tcp, "unexpected plaintext"} = delivered
      send(self(), delivered)
      {:ok, config} = TLS.config(%{tls: [backend: backend]})

      assert {:error, :pending_plaintext} = TLS.upgrade(tcp, Peer.client_options(), 100, config)
      assert_receive ^delivered
      assert {:error, :closed} = :gen_tcp.recv(server, 0, 1_000)
      Enum.each([server, listener], &:gen_tcp.close/1)
    end
  end

  defp restore_config(nil), do: Application.delete_env(:manifold_connectors, :tls_backends)
  defp restore_config(value), do: Application.put_env(:manifold_connectors, :tls_backends, value)
end
