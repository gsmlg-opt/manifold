defmodule Manifold.Connectors.DAV.TransportTest do
  use ExUnit.Case, async: true
  alias Manifold.Connectors.DAV.Transport

  test "DNS nonexistence remains distinguishable for regional discovery" do
    assert {:error, :nxdomain} =
             Transport.request(:get, "https://manifold-dav-no-such-host.invalid/", [], nil,
               timeout: 5_000
             )
  end

  test "real HTTP dispatch preserves DAV method and authorization with bounded body" do
    {url, peer} =
      server("HTTP/1.1 207 Multi-Status\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhello")

    assert {:ok, %{status: 207, body: "hello"}} =
             Transport.request(
               :propfind,
               url,
               [{"authorization", "Basic dummy"}, {"depth", "1"}],
               "<propfind/>"
             )

    request = Task.await(peer)
    assert request =~ "PROPFIND / HTTP/1.1"
    assert String.downcase(request) =~ "authorization: basic dummy"
  end

  test "transport does not automatically follow redirects or retry errors" do
    {url, peer} =
      server(
        "HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:1/\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
      )

    assert {:ok, %{status: 302, body: ""}} = Transport.request(:get, url, [], nil)
    Task.await(peer)

    {url, peer} =
      server("HTTP/1.1 503 Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")

    assert {:ok, %{status: 503}} = Transport.request(:get, url, [], nil)
    Task.await(peer)
  end

  test "streamed response byte limit fails instead of returning truncated success" do
    {url, peer} =
      server(
        "HTTP/1.1 200 OK\r\nContent-Length: 200\r\nConnection: close\r\n\r\n" <>
          String.duplicate("a", 200)
      )

    assert {:error, :response_limit} = Transport.request(:get, url, [], nil, max_body_bytes: 100)
    Task.await(peer)
  end

  test "HTTP response header parser enforces a finite byte limit" do
    {url, peer} =
      server(
        "HTTP/1.1 200 OK\r\nX-Huge: " <>
          String.duplicate("a", 70_000) <> "\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
      )

    assert {:error, :header_limit} = Transport.request(:get, url, [], nil)
    Task.await(peer)
  end

  test "peer closing without an HTTP response remains a transport failure" do
    {url, peer} = server("")

    assert {:error, :transport_failure} = Transport.request(:get, url, [], nil)
    assert Task.await(peer) =~ "GET / HTTP/1.1"
  end

  test "DAV request credentials never enter Finch telemetry" do
    handler = "dav-no-credential-telemetry-#{System.unique_integer([:positive])}"

    events = [
      [:finch, :request, :start],
      [:finch, :request, :stop],
      [:finch, :connect, :start],
      [:finch, :connect, :stop],
      [:finch, :send, :start],
      [:finch, :send, :stop],
      [:finch, :recv, :start],
      [:finch, :recv, :stop]
    ]

    :ok =
      :telemetry.attach_many(
        handler,
        events,
        fn event, _, metadata, parent -> send(parent, {:finch_event, event, metadata}) end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    {url, peer} = server("HTTP/1.1 200 OK\r\nContent-Length: 4\r\nConnection: close\r\n\r\nsafe")
    secret = Base.encode64("dummy-apple-id:dummy-app-password")

    assert {:ok, %{status: 200, body: "safe"}} =
             Transport.request(:get, url, [{"authorization", "Basic " <> secret}], nil)

    assert Task.await(peer) =~ secret
    refute_received {:finch_event, _, _}
  end

  test "absolute request timeout terminates a stalled peer" do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, {_, port}} = :inet.sockname(listener)
    parent = self()

    peer =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 5_000)
        _ = read_headers(socket, "")
        send(parent, :peer_received)
        result = :gen_tcp.recv(socket, 0, 5_000)
        :gen_tcp.close(socket)
        :gen_tcp.close(listener)
        result
      end)

    assert {:error, :timeout} =
             Transport.request(:get, "http://127.0.0.1:#{port}/", [], nil, timeout: 500)

    assert_received :peer_received
    assert {:error, :closed} = Task.await(peer)
  end

  test "Mint receive timeout stays a timeout when the adapter task finishes first" do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, {_, port}} = :inet.sockname(listener)
    parent = self()

    peer =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 5_000)
        request = read_headers(socket, "")
        send(parent, {:stalled_request, request})
        result = :gen_tcp.recv(socket, 0, 5_000)
        :gen_tcp.close(socket)
        :gen_tcp.close(listener)
        result
      end)

    requester =
      Task.async(fn ->
        receive do
          :request ->
            Transport.request(:get, "http://127.0.0.1:#{port}/", [], nil, timeout: 1_000)
        end
      end)

    Code.ensure_loaded!(Mint.HTTP)

    assert :erlang.trace_pattern({Mint.HTTP, :recv, 3}, [{:_, [], [{:return_trace}]}], [:local]) ==
             1

    :erlang.trace(requester.pid, true, [:call, :set_on_spawn, {:tracer, self()}])

    try do
      send(requester.pid, :request)
      assert_receive {:trace, worker, :call, {Mint.HTTP, :recv, [_, 0, remaining]}}, 2_000
      assert remaining > 0

      # Let the real socket timeout finish before the outer Task.yield can win.
      :erlang.suspend_process(requester.pid)
      monitor = Process.monitor(worker)
      assert_receive {:stalled_request, request}, 2_000
      assert request =~ "GET / HTTP/1.1"

      assert_receive {:trace, ^worker, :return_from, {Mint.HTTP, :recv, 3},
                      {:error, _, %Mint.TransportError{reason: :timeout}, _}},
                     2_000

      assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 2_000
      :erlang.resume_process(requester.pid)
      assert {:error, :timeout} = Task.await(requester)
      assert {:error, :closed} = Task.await(peer)
    after
      :erlang.trace_pattern({Mint.HTTP, :recv, 3}, false, [:local])

      if Process.alive?(requester.pid) do
        try do
          :erlang.resume_process(requester.pid)
        rescue
          ArgumentError -> :ok
        end
      end

      Task.shutdown(requester, :brutal_kill)
      Task.shutdown(peer, :brutal_kill)
      :gen_tcp.close(listener)
    end
  end

  defp server(response) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, {_, port}} = :inet.sockname(listener)

    peer =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 5_000)
        request = read_headers(socket, "")
        :gen_tcp.send(socket, response)
        :gen_tcp.close(socket)
        :gen_tcp.close(listener)
        request
      end)

    {"http://127.0.0.1:#{port}/", peer}
  end

  defp read_headers(socket, buffer) do
    if String.contains?(buffer, "\r\n\r\n") do
      buffer
    else
      {:ok, chunk} = :gen_tcp.recv(socket, 0, 5_000)
      read_headers(socket, buffer <> chunk)
    end
  end
end
