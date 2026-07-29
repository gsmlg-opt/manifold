defmodule Manifold.SMTPTest do
  use Manifold.DataCase, async: false

  alias Manifold.Accounts
  alias Manifold.Core.Error
  alias Manifold.Ingest.Schema.{DeliveryRecipient, InboundDelivery}
  alias Manifold.Repo
  alias Manifold.SMTP.{Admission, Listener, RateLimit, Session}

  @moduletag :tmp_dir

  defmodule TemporaryResolver do
    def resolve_recipient(_address) do
      {:error, Error.new(:temporary, :database_unavailable, "temporary failure")}
    end
  end

  defmodule AcceptingResolver do
    def resolve_recipient(address) do
      {:ok,
       %Manifold.Accounts.Route{
         original_recipient: address,
         canonical_recipient: String.downcase(address),
         plus_tag: nil,
         domain_id: Ecto.UUID.generate(),
         mailbox_ids: [Ecto.UUID.generate()]
       }}
    end
  end

  defmodule FailingIngest do
    def accept_transport(_data, _attrs, _routes) do
      {:error, Error.new(:temporary, :acceptance_failed, "injected failure")}
    end
  end

  defmodule RecordingIngest do
    use Agent

    def start_link(_opts) do
      Agent.start_link(fn -> %{calls: [], failures_remaining: 0} end, name: __MODULE__)
    end

    def fail_next(count) do
      Agent.update(__MODULE__, &%{&1 | failures_remaining: count})
    end

    def calls do
      Agent.get(__MODULE__, &Enum.reverse(&1.calls))
    end

    def accept_transport(_data, attrs, routes) do
      call = %{attrs: attrs, routes: routes}

      Agent.get_and_update(__MODULE__, fn state ->
        state = %{state | calls: [call | state.calls]}

        if state.failures_remaining > 0 do
          error = Error.new(:temporary, :acceptance_failed, "injected failure")
          {{:error, error}, %{state | failures_remaining: state.failures_remaining - 1}}
        else
          {{:ok, %{ingest_id: Ecto.UUID.generate()}}, state}
        end
      end)
    end
  end

  setup %{tmp_dir: tmp_dir} do
    old_spool = Application.fetch_env!(:manifold_storage, :spool_dir)
    old_raw = Application.fetch_env!(:manifold_storage, :raw_store_dir)

    Application.put_env(:manifold_storage, :spool_dir, Path.join(tmp_dir, "spool"))
    Application.put_env(:manifold_storage, :raw_store_dir, Path.join(tmp_dir, "raw"))

    on_exit(fn ->
      Application.put_env(:manifold_storage, :spool_dir, old_spool)
      Application.put_env(:manifold_storage, :raw_store_dir, old_raw)
    end)

    :ok
  end

  test "unknown recipient returns 550 at RCPT TO" do
    port = start_smtp!()
    socket = connect!(port)
    ehlo(socket)
    mail_from(socket)

    send_line(socket, "RCPT TO:<missing@example.test>\r\n")
    assert ["550 5.1.1" <> _] = recv_response(socket)
  end

  test "known recipient accepts DATA and creates durable delivery" do
    %{domain: domain} = mailbox_fixture()
    port = start_smtp!()
    socket = connect!(port)

    ehlo(socket)
    mail_from(socket)
    rcpt_to(socket, "inbox@#{domain.normalized_domain}")
    data(socket, "Subject: ok\r\n\r\nBody\r\n")

    assert Repo.aggregate(InboundDelivery, :count) == 1
    assert [%InboundDelivery{raw_storage_state: "spooled"}] = Repo.all(InboundDelivery)
  end

  test "multiple recipients are preserved" do
    %{domain: domain} = mailbox_fixture()
    {:ok, _mailbox} = Accounts.create_mailbox(domain, %{local_part: "second"})
    port = start_smtp!()
    socket = connect!(port)

    ehlo(socket)
    mail_from(socket)
    rcpt_to(socket, "inbox@#{domain.normalized_domain}")
    rcpt_to(socket, "second@#{domain.normalized_domain}")
    data(socket, "Subject: ok\r\n\r\nBody\r\n")

    assert Repo.aggregate(DeliveryRecipient, :count) == 2
  end

  test "oversized message is rejected" do
    %{domain: domain} = mailbox_fixture()
    port = start_smtp!(max_message_bytes: 12)
    socket = connect!(port)

    ehlo(socket)
    mail_from(socket)
    rcpt_to(socket, "inbox@#{domain.normalized_domain}")

    send_line(socket, "DATA\r\n")
    assert ["354" <> _] = recv_response(socket)
    send_line(socket, "Subject: too large\r\n\r\n01234567890123456789\r\n.\r\n")
    assert ["552" <> _] = recv_response(socket)
  end

  test "temporary recipient resolver failure maps to 451" do
    port = start_smtp!(resolver: TemporaryResolver)
    socket = connect!(port)

    ehlo(socket)
    mail_from(socket)
    send_line(socket, "RCPT TO:<inbox@example.test>\r\n")

    assert ["451 4.3.0" <> _] = recv_response(socket)
  end

  test "acceptance failure never returns 250" do
    port = start_smtp!(resolver: AcceptingResolver, ingest: FailingIngest)
    socket = connect!(port)

    ehlo(socket)
    mail_from(socket)
    rcpt_to(socket, "inbox@example.test")

    send_line(socket, "DATA\r\n")
    assert ["354" <> _] = recv_response(socket)
    send_line(socket, "Subject: no\r\n\r\nBody\r\n.\r\n")

    assert ["451 4.3.0" <> _] = recv_response(socket)
  end

  test "failed DATA does not leak recipients into a following null-sender transaction" do
    start_supervised!(RecordingIngest)
    RecordingIngest.fail_next(1)

    port = start_smtp!(resolver: AcceptingResolver, ingest: RecordingIngest)
    socket = connect!(port)

    ehlo(socket)
    mail_from(socket)
    rcpt_to(socket, "first@example.test")
    send_data(socket, "Subject: first\r\n\r\nBody\r\n")
    assert ["451 4.3.0" <> _] = recv_response(socket)

    send_line(socket, "MAIL FROM:<>\r\n")
    assert ["250" <> _] = recv_response(socket)
    rcpt_to(socket, "second@example.test")
    data(socket, "Subject: second\r\n\r\nBody\r\n")

    assert [
             %{attrs: %{original_recipients: ["first@example.test"]}},
             %{
               attrs: %{envelope_from: "", original_recipients: ["second@example.test"]},
               routes: [%{original_recipient: "second@example.test"}]
             }
           ] = RecordingIngest.calls()
  end

  test "successful DATA does not leak recipients into the next transaction" do
    start_supervised!(RecordingIngest)

    port = start_smtp!(resolver: AcceptingResolver, ingest: RecordingIngest)
    socket = connect!(port)

    ehlo(socket)
    mail_from(socket)
    rcpt_to(socket, "first@example.test")
    data(socket, "Subject: first\r\n\r\nBody\r\n")

    send_line(socket, "MAIL FROM:<second-sender@example.test>\r\n")
    assert ["250" <> _] = recv_response(socket)
    rcpt_to(socket, "second@example.test")
    data(socket, "Subject: second\r\n\r\nBody\r\n")

    assert [
             %{attrs: %{original_recipients: ["first@example.test"]}},
             %{
               attrs: %{
                 envelope_from: "second-sender@example.test",
                 original_recipients: ["second@example.test"]
               },
               routes: [%{original_recipient: "second@example.test"}]
             }
           ] = RecordingIngest.calls()
  end

  test "failed DATA emits a stop event and resets transaction state" do
    attach_transaction_telemetry()

    state = %Session{
      peer_ip: "127.0.0.1",
      helo: "client.example",
      mail_from: "sender@example.test",
      recipients: ["inbox@example.test"],
      routes: [%{original_recipient: "inbox@example.test"}],
      options: [
        max_message_bytes: 1024,
        max_recipients: 100,
        ingest: FailingIngest
      ]
    }

    assert {:error, "451 4.3.0 local accept failure",
            %Session{mail_from: nil, recipients: [], routes: []}} =
             Session.handle_DATA(nil, nil, "Subject: no\r\n\r\nBody\r\n", state)

    assert_receive {[:manifold, :smtp, :transaction, :start], %{raw_size: raw_size}, %{}}

    assert_receive {[:manifold, :smtp, :transaction, :stop], %{raw_size: ^raw_size},
                    %{result: :local_accept_failure}}
  end

  test "oversized DATA emits a stop event and resets transaction state" do
    attach_transaction_telemetry()

    state = %Session{
      peer_ip: "127.0.0.1",
      mail_from: "sender@example.test",
      recipients: ["inbox@example.test"],
      routes: [%{original_recipient: "inbox@example.test"}],
      options: [max_message_bytes: 4, max_recipients: 100]
    }

    assert {:error, "552 5.3.4 message too large",
            %Session{mail_from: nil, recipients: [], routes: []}} =
             Session.handle_DATA(nil, nil, "12345", state)

    assert_receive {[:manifold, :smtp, :transaction, :start], %{raw_size: 5}, %{}}

    assert_receive {[:manifold, :smtp, :transaction, :stop], %{raw_size: 5},
                    %{result: :message_too_large}}
  end

  test "null MAIL FROM clears stale transaction state" do
    state = %Session{
      peer_ip: "127.0.0.1",
      helo: "client.example",
      mail_from: "stale@example.test",
      recipients: ["stale@example.test"],
      routes: [%{original_recipient: "stale@example.test"}],
      options: [max_message_bytes: 1024, max_recipients: 100]
    }

    assert {:ok,
            %Session{
              helo: "client.example",
              mail_from: "",
              recipients: [],
              routes: []
            }} = Session.handle_MAIL("", state)
  end

  test "DATA receive errors clear transaction state" do
    state = %Session{
      peer_ip: "127.0.0.1",
      mail_from: "stale@example.test",
      recipients: ["stale@example.test"],
      routes: [%{original_recipient: "stale@example.test"}],
      options: [max_message_bytes: 1024, max_recipients: 100]
    }

    assert {:ok, %Session{mail_from: nil, recipients: [], routes: []}} =
             Session.handle_error(:data_rejected, :size_exceeded, state)
  end

  test "EHLO does not advertise AUTH or SMTPUTF8" do
    port = start_smtp!()
    socket = connect!(port)

    lines = ehlo(socket)
    response = Enum.join(lines)

    assert response =~ "8BITMIME"
    assert response =~ "PIPELINING"
    assert response =~ "SIZE 26214400"
    refute response =~ "AUTH"
    refute response =~ "SMTPUTF8"
    refute response =~ "STARTTLS"
  end

  test "recipient count is enforced over TCP" do
    port = start_smtp!(resolver: AcceptingResolver, max_recipients: 1)
    socket = connect!(port)

    ehlo(socket)
    mail_from(socket)
    rcpt_to(socket, "first@example.test")
    send_line(socket, "RCPT TO:<second@example.test>\r\n")

    assert ["452 4.3.1" <> _] = recv_response(socket)
  end

  test "invalid sender and recipient syntax return 501" do
    port = start_smtp!()
    socket = connect!(port)

    ehlo(socket)
    send_line(socket, "MAIL FROM:not-an-address\r\n")
    assert ["501" <> _] = recv_response(socket)

    mail_from(socket)
    send_line(socket, "RCPT TO:not-an-address\r\n")
    assert ["501" <> _] = recv_response(socket)
  end

  test "RSET clears the current transaction" do
    start_supervised!(RecordingIngest)
    port = start_smtp!(resolver: AcceptingResolver, ingest: RecordingIngest)
    socket = connect!(port)

    ehlo(socket)
    mail_from(socket)
    rcpt_to(socket, "discarded@example.test")
    send_line(socket, "RSET\r\n")
    assert ["250" <> _] = recv_response(socket)

    send_line(socket, "MAIL FROM:<>\r\n")
    assert ["250" <> _] = recv_response(socket)
    rcpt_to(socket, "accepted@example.test")
    data(socket, "Subject: accepted\r\n\r\nBody\r\n")

    assert [
             %{
               attrs: %{envelope_from: "", original_recipients: ["accepted@example.test"]},
               routes: [%{original_recipient: "accepted@example.test"}]
             }
           ] = RecordingIngest.calls()
  end

  test "NOOP succeeds and QUIT closes the connection" do
    port = start_smtp!()
    socket = connect!(port)

    send_line(socket, "NOOP\r\n")
    assert ["250" <> _] = recv_response(socket)

    send_line(socket, "QUIT\r\n")
    assert ["221" <> _] = recv_response(socket)
    assert {:error, :closed} = :gen_tcp.recv(socket, 0, 2_000)
  end

  test "AUTH and SMTPUTF8 remain unavailable" do
    port = start_smtp!()
    socket = connect!(port)

    ehlo(socket)
    send_line(socket, "AUTH PLAIN\r\n")
    assert [auth_response] = recv_response(socket)
    refute String.starts_with?(auth_response, "235")
    refute String.starts_with?(auth_response, "334")

    send_line(socket, "MAIL FROM:<sender@example.net> SMTPUTF8\r\n")
    assert ["555" <> _] = recv_response(socket)
  end

  test "fixed-window rate limit refills deterministically" do
    assert {:ok, first} = RateLimit.check(nil, 2, 1_000, 100)
    assert {:ok, second} = RateLimit.check(first, 2, 1_000, 200)
    assert {:error, 800, ^second} = RateLimit.check(second, 2, 1_000, 300)
    assert {:ok, reset} = RateLimit.check(second, 2, 1_000, 1_100)
    assert reset.count == 1
    assert reset.started_at_ms == 1_100
  end

  test "admission isolates peers and releases crashed session leases" do
    admission = start_admission!(max_connections_per_peer: 1)
    first = spawn(fn -> Process.sleep(:infinity) end)
    second = spawn(fn -> Process.sleep(:infinity) end)
    third = spawn(fn -> Process.sleep(:infinity) end)

    on_exit(fn -> Enum.each([first, second, third], &Process.exit(&1, :kill)) end)

    assert :ok = Admission.acquire_connection("192.0.2.1", first, admission)

    assert {:error, :connection_limit} =
             Admission.acquire_connection("192.0.2.1", second, admission)

    assert :ok = Admission.acquire_connection("192.0.2.2", second, admission)
    Process.exit(first, :kill)

    assert_eventually(fn ->
      Admission.acquire_connection("192.0.2.1", third, admission) == :ok
    end)
  end

  test "admission prunes expired peer rate windows" do
    {:ok, clock} = Agent.start_link(fn -> 100 end)
    admission = start_admission!(clock: fn -> Agent.get(clock, & &1) end)
    owner = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> Process.exit(owner, :kill) end)

    assert :ok = Admission.acquire_connection("192.0.2.10", owner, admission)
    assert :ok = Admission.allow_transaction("192.0.2.10", admission)
    assert :ok = Admission.release_connection(owner, admission)

    assert map_size(:sys.get_state(admission).connection_windows) == 1
    assert map_size(:sys.get_state(admission).transaction_windows) == 1

    Agent.update(clock, fn _now -> 60_100 end)
    send(admission, :prune)

    assert_eventually(fn ->
      state = :sys.get_state(admission)
      state.connection_windows == %{} and state.transaction_windows == %{}
    end)
  end

  test "per-peer connection limit rejects a second TCP session with 421" do
    admission = start_admission!(max_connections_per_peer: 1)
    port = start_smtp!(admission: admission)
    first = connect!(port)

    assert {:ok, second} =
             :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, packet: :line, active: false])

    assert ["421 4.7.0" <> _] = recv_response(second)
    :ok = :gen_tcp.close(first)
  end

  test "per-peer connection rate applies after a session releases its lease" do
    admission = start_admission!(connection_rate_limit: 1)
    port = start_smtp!(admission: admission)
    first = connect!(port)

    send_line(first, "QUIT\r\n")
    assert ["221" <> _] = recv_response(first)

    assert {:ok, second} =
             :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, packet: :line, active: false])

    assert ["421 4.7.0" <> _] = recv_response(second)
  end

  test "per-peer transaction rate rejects MAIL FROM temporarily" do
    admission = start_admission!(transaction_rate_limit: 1)
    port = start_smtp!(admission: admission)
    socket = connect!(port)

    ehlo(socket)
    mail_from(socket)
    send_line(socket, "RSET\r\n")
    assert ["250" <> _] = recv_response(socket)

    send_line(socket, "MAIL FROM:<second@example.net>\r\n")
    assert ["451 4.7.0" <> _] = recv_response(socket)
  end

  test "listener configures conservative Ranch connection limits" do
    with_smtp_config(max_connections: 12, acceptors: 3)

    assert %{
             start:
               {:ranch_embedded_sup, :start_link,
                [
                  :manifold_smtp_listener,
                  :ranch_tcp,
                  %{max_connections: 12, num_acceptors: 3},
                  :gen_smtp_server_session,
                  _
                ]}
           } = Listener.child_spec()
  end

  test "listener fails fast when only one TLS file is configured" do
    with_smtp_config(tls_certfile: "/tmp/cert.pem", tls_keyfile: nil)

    assert_raise ArgumentError, ~r/both .*TLS.*cert.*key/i, fn ->
      Listener.child_spec()
    end

    with_smtp_config(tls_certfile: nil, tls_keyfile: "/tmp/key.pem")

    assert_raise ArgumentError, ~r/both .*TLS.*cert.*key/i, fn ->
      Listener.child_spec()
    end

    with_smtp_config(tls_certfile: "", tls_keyfile: "/tmp/key.pem")

    assert_raise ArgumentError, ~r/both .*TLS.*cert.*key/i, fn ->
      Listener.child_spec()
    end
  end

  defp mailbox_fixture do
    suffix = System.unique_integer([:positive])
    {:ok, domain} = Accounts.create_domain(%{name: "smtp#{suffix}.test"})
    {:ok, mailbox} = Accounts.create_mailbox(domain, %{local_part: "inbox"})
    %{domain: domain, mailbox: mailbox}
  end

  defp start_smtp!(opts \\ []) do
    port = Keyword.get(opts, :port, 26_000 + rem(System.unique_integer([:positive]), 1000))
    ref = {:manifold_smtp_test, self(), port}

    callback_options = [
      max_message_bytes: Keyword.get(opts, :max_message_bytes, 25 * 1024 * 1024),
      max_recipients: Keyword.get(opts, :max_recipients, 100),
      tls_enabled?: false,
      admission: Keyword.get(opts, :admission),
      resolver: Keyword.get(opts, :resolver, Manifold.Accounts),
      ingest: Keyword.get(opts, :ingest, Manifold.Ingest)
    ]

    options = [
      domain: ~c"localhost",
      address: {127, 0, 0, 1},
      port: port,
      sessionoptions: [{:allow_bare_newlines, false}, {:callbackoptions, callback_options}]
    ]

    assert {:ok, _pid} = :gen_smtp_server.start(ref, Manifold.SMTP.Session, options)

    on_exit(fn ->
      :gen_smtp_server.stop(ref)
    end)

    port
  end

  defp start_admission!(overrides) do
    defaults = [
      name: nil,
      max_connections_per_peer: 8,
      connection_rate_limit: 60,
      connection_rate_window_ms: 60_000,
      transaction_rate_limit: 120,
      transaction_rate_window_ms: 60_000
    ]

    start_supervised!({Admission, Keyword.merge(defaults, overrides)})
  end

  defp connect!(port) do
    assert {:ok, socket} =
             :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, packet: :line, active: false])

    assert ["220" <> _] = recv_response(socket)
    socket
  end

  defp ehlo(socket) do
    send_line(socket, "EHLO client.example\r\n")
    assert [_ | _] = lines = recv_response(socket)
    lines
  end

  defp mail_from(socket) do
    send_line(socket, "MAIL FROM:<sender@example.net>\r\n")
    assert ["250" <> _] = recv_response(socket)
  end

  defp rcpt_to(socket, address) do
    send_line(socket, "RCPT TO:<#{address}>\r\n")
    assert ["250" <> _] = recv_response(socket)
  end

  defp data(socket, body) do
    send_line(socket, "DATA\r\n")
    assert ["354" <> _] = recv_response(socket)
    send_line(socket, body <> ".\r\n")
    assert ["250 2.0.0 accepted as" <> _] = recv_response(socket)
  end

  defp send_data(socket, body) do
    send_line(socket, "DATA\r\n")
    assert ["354" <> _] = recv_response(socket)
    send_line(socket, body <> ".\r\n")
  end

  defp send_line(socket, line), do: :ok = :gen_tcp.send(socket, line)

  defp recv_response(socket) do
    {:ok, first} = :gen_tcp.recv(socket, 0, 2_000)
    code = binary_part(first, 0, 3)
    trimmed = String.trim_trailing(first)

    if String.starts_with?(trimmed, code <> "-") do
      collect_response(socket, code, [trimmed])
    else
      [trimmed]
    end
  end

  defp collect_response(socket, code, lines) do
    {:ok, line} = :gen_tcp.recv(socket, 0, 2_000)
    trimmed = String.trim_trailing(line)

    if String.starts_with?(trimmed, code <> "-") do
      collect_response(socket, code, [trimmed | lines])
    else
      Enum.reverse([trimmed | lines])
    end
  end

  defp attach_transaction_telemetry do
    handler_id = "smtp-test-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach_many(
        handler_id,
        [
          [:manifold, :smtp, :transaction, :start],
          [:manifold, :smtp, :transaction, :stop]
        ],
        fn event, measurements, metadata, pid ->
          send(pid, {event, measurements, metadata})
        end,
        test_pid
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  defp assert_eventually(fun, attempts \\ 20)
  defp assert_eventually(fun, 0), do: assert(fun.())

  defp assert_eventually(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp with_smtp_config(overrides) do
    previous =
      Map.new(overrides, fn {key, _value} ->
        {key, Application.fetch_env(:manifold_smtp, key)}
      end)

    Enum.each(overrides, fn {key, value} ->
      Application.put_env(:manifold_smtp, key, value)
    end)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:manifold_smtp, key, value)
        {key, :error} -> Application.delete_env(:manifold_smtp, key)
      end)
    end)
  end
end
