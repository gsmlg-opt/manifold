Code.require_file("../../../../../test/support/http_wire.exs", __DIR__)

defmodule Manifold.Edge.HTTPServerWireTest do
  use Manifold.Edge.DataCase, async: false

  alias Manifold.Core.{RouteSnapshotDigest, SignedRequest}
  alias Manifold.Edge
  alias Manifold.Edge.SMTP
  alias Manifold.HTTPWire, as: Wire

  @moduletag :tmp_dir
  @secret "wire-test-edge-secret"
  @installation_id "wire-test-installation"
  @authority "edge.example.test"
  @env_keys [Manifold.Edge.Repo, :api_server, :api_bind, :api_port, :api, :reconciler_enabled]

  setup_all do
    previous = Map.new(@env_keys, &{&1, Application.fetch_env(:manifold_edge, &1)})
    :ok = Application.stop(:manifold_edge)

    # The test helper owns the Sandbox Repo independently of the application.
    Application.delete_env(:manifold_edge, Manifold.Edge.Repo)
    Application.put_env(:manifold_edge, :reconciler_enabled, false)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:manifold_edge, key, value)
        {key, :error} -> Application.delete_env(:manifold_edge, key)
      end)

      Application.delete_env(:manifold_edge, Manifold.Edge.Repo)
      {:ok, _} = Application.ensure_all_started(:manifold_edge)

      case previous[Manifold.Edge.Repo] do
        {:ok, value} -> Application.put_env(:manifold_edge, Manifold.Edge.Repo, value)
        :error -> :ok
      end
    end)

    :ok
  end

  setup tags do
    Application.put_env(:manifold_edge, :api_server, !tags[:server_disabled])
    Application.put_env(:manifold_edge, :api_bind, if(tags[:ipv6], do: "::1", else: "127.0.0.1"))
    Application.put_env(:manifold_edge, :api_port, 0)

    Application.put_env(:manifold_edge, :api,
      installation_id: @installation_id,
      authority: @authority,
      shared_secret: @secret,
      max_clock_skew_seconds: 300,
      max_request_bytes: Map.get(tags, :max_request_bytes, 2_097_152)
    )

    supervisor =
      start_supervised!(%{
        id: Manifold.Edge.Supervisor,
        start: {Manifold.Edge.Application, :start, [:normal, []]},
        type: :supervisor
      })

    if tags[:server_disabled] do
      %{supervisor: supervisor}
    else
      assert [{{Gaoxy.HTTP, :edge_api}, listener, :worker, [Gaoxy.HTTP]}] =
               Supervisor.which_children(supervisor)

      assert %{local: {:ok, {ip, port}}} = Gaoxy.info(listener, :edge_api)
      assert ip == if(tags[:ipv6], do: {0, 0, 0, 0, 0, 0, 0, 1}, else: {127, 0, 0, 1})
      assert port > 0
      %{supervisor: supervisor, listener: listener, ip: ip, port: port}
    end
  end

  @tag :server_disabled
  test "api_server false starts no listener", %{supervisor: supervisor} do
    assert Supervisor.which_children(supervisor) == []
  end

  test "application owns an IPv4 listener and preserves signed raw path and body", context do
    response = request(context, "GET", "/api/v1/%73tatus", "", "encoded-path")
    assert response.status == 200
    assert %{"pending_deliveries" => 0} = Jason.decode!(response.body)

    body = snapshot_body() <> "\r\n"
    response = request(context, "PUT", "/api/v1/route-snapshots", body, "snapshot")
    assert response.status == 204
    assert {:ok, %{revision: 1}} = Edge.active_route_snapshot()
  end

  test "stopping the application supervisor closes its listener", context do
    assert request(context, "GET", "/api/v1/status", "", "before-stop").status == 200
    assert :ok = stop_supervised(Manifold.Edge.Supervisor)

    assert {:error, :econnrefused} =
             :gen_tcp.connect(context.ip, context.port, [:binary, active: false], 5_000)
  end

  test "application supervision allows an admitted request to finish drain cleanup", context do
    body = String.duplicate("x", 2_097_152)
    timestamp = DateTime.utc_now() |> DateTime.to_unix()

    signature =
      SignedRequest.sign(@secret, "GET", "/api/v1/status", timestamp, body,
        installation_id: @installation_id,
        authority: @authority,
        nonce: "draining-request"
      )

    socket = Wire.connect(context.port)

    try do
      :ok =
        :gen_tcp.send(socket, [
          "GET /api/v1/status HTTP/1.1\r\nHost: ",
          @authority,
          "\r\nConnection: close\r\nExpect: 100-continue\r\nContent-Length: ",
          Integer.to_string(byte_size(body)),
          "\r\nx-manifold-installation: ",
          @installation_id,
          "\r\nx-manifold-timestamp: ",
          Integer.to_string(timestamp),
          "\r\nx-manifold-nonce: draining-request\r\nx-manifold-signature: ",
          signature,
          "\r\n\r\n"
        ])

      assert {100, _headers} = Wire.response_head(socket)
      assert %{active: 1} = Gaoxy.status(context.listener, :edge_api)
      monitor = Process.monitor(context.listener)
      started = System.monotonic_time(:millisecond)

      stopping =
        Task.async(fn ->
          Supervisor.terminate_child(context.supervisor, {Gaoxy.HTTP, :edge_api})
        end)

      token = make_ref()
      {:ok, timer} = :timer.send_interval(100, {:progress_drain_body, token})

      {reason, sent_bytes} =
        try do
          await_draining_listener(socket, context.listener, monitor, token, 0, started + 8_000)
        after
          :timer.cancel(timer)
        end

      elapsed = System.monotonic_time(:millisecond) - started
      assert :ok = Task.await(stopping, 2_000)
      assert sent_bytes > 0

      assert reason == :shutdown,
             "Gaoxy instance exited #{inspect(reason)} after #{elapsed}ms with " <>
               "#{sent_bytes} admitted body bytes sent during shutdown"
    after
      :gen_tcp.close(socket)
    end
  end

  @tag :ipv6
  test "application parses the IPv6 bind and serves signed requests", context do
    response = request(context, "GET", "/api/v1/status", "", "ipv6")
    assert response.status == 200
  end

  test "rejects changes to signed method, raw path, authority and body", context do
    for {field, value} <- [
          method: "POST",
          path: "/api/v1/deliveries",
          host: "other.example.test",
          body: "changed body"
        ] do
      response =
        request(context, "GET", "/api/v1/status", "", "tampered-#{field}", [{field, value}])

      assert response.status == 401
      assert %{"error" => "invalid_signature"} = Jason.decode!(response.body)
    end
  end

  test "rejects a replay and every repeated authentication header", context do
    assert request(context, "GET", "/api/v1/status", "", "replay").status == 200
    assert request(context, "GET", "/api/v1/status", "", "replay").status == 401

    for header <-
          ~w(x-manifold-installation x-manifold-timestamp x-manifold-nonce x-manifold-signature) do
      response =
        request(context, "GET", "/api/v1/status", "", "duplicate-#{header}",
          duplicate_header: header
        )

      assert response.status == 401
      assert %{"error" => "invalid_signature"} = Jason.decode!(response.body)
    end

    for combined_nonce <- ["left, right", "left,right"] do
      response =
        request(context, "GET", "/api/v1/status", "", combined_nonce,
          nonce_values: ["left", "right"]
        )

      assert response.status == 401
    end
  end

  test "preserves the application request body limit", context do
    config = Application.fetch_env!(:manifold_edge, :api)
    Application.put_env(:manifold_edge, :api, Keyword.put(config, :max_request_bytes, 64))

    assert request(context, "GET", "/api/v1/status", String.duplicate("x", 64), "at-limit").status ==
             200

    response =
      request(context, "PUT", "/api/v1/route-snapshots", String.duplicate("x", 65), "too-large")

    assert response.status == 413
    assert %{"error" => "request_too_large"} = Jason.decode!(response.body)
  end

  test "accepts the default two-mebibyte limit and rejects the next byte", context do
    body = String.duplicate("x", 2_097_152)
    assert request(context, "GET", "/api/v1/status", body, "default-limit").status == 200

    response = request(context, "GET", "/api/v1/status", body <> "x", "over-default-limit")
    assert response.status == 413
    assert %{"error" => "request_too_large"} = Jason.decode!(response.body)
  end

  @tag max_request_bytes: 8_388_609
  test "honors configured request limits above Gaoxy's default body limit", context do
    body = String.duplicate("x", 8_388_609)
    assert request(context, "GET", "/api/v1/status", body, "configured-limit").status == 200

    response = request(context, "GET", "/api/v1/status", body <> "x", "over-configured-limit")
    assert response.status == 413
    assert %{"error" => "request_too_large"} = Jason.decode!(response.body)
  end

  test "serves the complete raw spool file with private response headers", context do
    assert request(context, "PUT", "/api/v1/route-snapshots", snapshot_body(), "install").status ==
             204

    {:ok, snapshot} = SMTP.begin_transaction()
    {:ok, route} = SMTP.resolve_recipient("team@example.test", snapshot)

    raw =
      "From: sender@example.net\r\nSubject: wire raw\r\n\r\n" <>
        String.duplicate("raw\0\r\n", 30_000)

    {:ok, delivery} =
      SMTP.accept_transport(
        raw,
        %{
          peer_ip: "192.0.2.10",
          envelope_from: "sender@example.net",
          received_at: DateTime.utc_now(),
          original_recipients: ["team@example.test"]
        },
        [route],
        spool_opts: [root: context.tmp_dir]
      )

    response = request(context, "GET", "/api/v1/deliveries/#{delivery.id}/raw", "", "raw")
    assert response.status == 200
    assert response.body == raw
    assert Wire.header(response.headers, "cache-control") == "no-store, private"
    assert Wire.header(response.headers, "content-type") =~ "message/rfc822"
    assert String.to_integer(Wire.header(response.headers, "content-length")) == byte_size(raw)
  end

  defp await_draining_listener(socket, listener, monitor, token, sent_bytes, deadline) do
    receive do
      {:DOWN, ^monitor, :process, ^listener, reason} ->
        {reason, sent_bytes}

      {:progress_drain_body, ^token} ->
        chunk = String.duplicate("x", 16_384)

        sent_bytes =
          case :gen_tcp.send(socket, chunk) do
            :ok -> sent_bytes + byte_size(chunk)
            {:error, :closed} -> sent_bytes
          end

        await_draining_listener(socket, listener, monitor, token, sent_bytes, deadline)
    after
      max(0, deadline - System.monotonic_time(:millisecond)) ->
        flunk("application-owned listener did not stop during its drain budget")
    end
  end

  defp request(context, method, path, body, nonce, changes \\ []) do
    timestamp = DateTime.utc_now() |> DateTime.to_unix()

    signature =
      SignedRequest.sign(@secret, method, path, timestamp, body,
        installation_id: @installation_id,
        authority: @authority,
        nonce: nonce
      )

    headers = [
      {"host", Keyword.get(changes, :host, @authority)},
      {"connection", "close"},
      {"content-type", "application/json"},
      {"x-manifold-installation", @installation_id},
      {"x-manifold-timestamp", Integer.to_string(timestamp)},
      {"x-manifold-nonce", nonce},
      {"x-manifold-signature", signature}
    ]

    headers =
      case Keyword.get(changes, :duplicate_header) do
        nil -> headers
        name -> headers ++ [List.keyfind(headers, name, 0)]
      end

    headers =
      case Keyword.get(changes, :nonce_values) do
        nil ->
          headers

        values ->
          List.keydelete(headers, "x-manifold-nonce", 0) ++
            Enum.map(values, &{"x-manifold-nonce", &1})
      end

    body = Keyword.get(changes, :body, body)
    headers = headers ++ [{"content-length", byte_size(body)}]
    lines = Enum.map(headers, fn {key, value} -> [key, ": ", to_string(value), "\r\n"] end)
    ip = context.ip
    port = context.port
    family = if tuple_size(ip) == 8, do: :inet6, else: :inet
    {:ok, socket} = :gen_tcp.connect(ip, port, [:binary, family, active: false], 5_000)

    try do
      :ok =
        :gen_tcp.send(socket, [
          Keyword.get(changes, :method, method),
          " ",
          Keyword.get(changes, :path, path),
          " HTTP/1.1\r\n",
          lines,
          "\r\n",
          body
        ])

      Wire.response(socket, Keyword.get(changes, :method, method))
    after
      :gen_tcp.close(socket)
    end
  end

  defp snapshot_body do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    domains = []

    routes = [
      %{
        canonical_address: "team@example.test",
        domain_id: "domain-1",
        mailbox_ids: ["mailbox-1"],
        plus_addressing_enabled: true
      }
    ]

    {:ok, digest} = RouteSnapshotDigest.compute(1, domains, routes)

    Jason.encode!(%{
      schema_version: 1,
      revision: 1,
      digest: digest,
      generated_at: DateTime.add(now, -60, :second),
      expires_at: DateTime.add(now, 3600, :second),
      domains: domains,
      routes: routes
    })
  end
end
