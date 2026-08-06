defmodule Manifold.Connectors.EAS.ClientProtocolTest do
  use ExUnit.Case, async: true

  alias Manifold.Connectors.EAS.Client
  alias Manifold.Connectors.EAS.WBXML
  alias Manifold.Connectors.Provider.Error

  test "auth_username prefixes optional domain" do
    assert Client.auth_username(%{username: "user@ex.com", domain: nil}) == "user@ex.com"
    assert Client.auth_username(%{username: "user@ex.com", domain: ""}) == "user@ex.com"
    assert Client.auth_username(%{username: "user", domain: "CORP"}) == "CORP\\user"

    assert Client.auth_username(%{username: "CORP\\user", domain: "OTHER"}) == "CORP\\user"
  end

  test "format_transport_reason clarifies DNS Host failures vs Domain field" do
    message = Client.format_transport_reason(%Req.TransportError{reason: :nxdomain})
    assert message =~ "DNS lookup failed for Host"
    assert message =~ "not the optional Domain"
    refute message =~ "non-existing domain"

    message = Client.format_transport_reason(%Req.TransportError{reason: :econnrefused})
    assert message =~ "connection to Host failed"
  end

  test "connect surfaces DNS failure instead of swallowing OPTIONS errors" do
    settings = %{
      host: "ex.exmail.qq.om",
      port: 443,
      path: "/Microsoft-Server-ActiveSync",
      username: "user@ex.com",
      password: "secret",
      device_id: "ApplABCD1234EFGH",
      device_type: "iPhone",
      protocol_version: "14.1",
      emit_activity: false
    }

    assert {:error, %Error{code: :connect_failed, message: message}} = Client.connect(settings)
    assert message =~ "DNS lookup failed for Host"
    refute message =~ "non-existing domain"
  end

  test "query_user strips domain for User query parameter" do
    assert Client.query_user(%{username: "user@ex.com", domain: nil}) == "user@ex.com"
    assert Client.query_user(%{username: "user", domain: "CORP"}) == "user"
    assert Client.query_user(%{username: "CORP\\user", domain: nil}) == "user"
  end

  test "command_url uses MS-ASHTTP Cmd-first order, omits default port, leaves @ unencoded" do
    url =
      Client.command_url(
        %{
          host: "ex.exmail.qq.com",
          port: 443,
          path: "/Microsoft-Server-ActiveSync/",
          domain: "CORP",
          username: "user@ex.com",
          device_id: "ApplABCD1234EFGH",
          device_type: "iPhone"
        },
        "FolderSync"
      )

    assert url ==
             "https://ex.exmail.qq.com/Microsoft-Server-ActiveSync?Cmd=FolderSync&User=user@ex.com&DeviceId=ApplABCD1234EFGH&DeviceType=iPhone"

    refute url =~ "%40"
    refute url =~ ":443"
    refute url =~ "CORP"
  end

  test "command_url base64 mode encodes MS-ASHTTP binary query" do
    url =
      Client.command_url(
        %{
          host: "ex.exmail.qq.com",
          port: 443,
          path: "/Microsoft-Server-ActiveSync",
          username: "user@ex.com",
          device_id: "ApplABCD1234EFGH",
          device_type: "iPhone",
          protocol_version: "14.1"
        },
        "FolderSync",
        :base64,
        "0"
      )

    assert String.starts_with?(url, "https://ex.exmail.qq.com/Microsoft-Server-ActiveSync?")
    query = url |> URI.parse() |> Map.fetch!(:query)
    assert {:ok, raw} = Base.decode64(query)
    # protocol 141, FolderSync command 9, locale 0x0409
    assert <<141, 9, 0x09, 0x04, _rest::binary>> = raw
  end

  test "pick_protocol_version prefers advertised mutual versions" do
    headers = [{"ms-asprotocolversions", "12.1,14.0,14.1"}]

    assert Client.pick_protocol_version(headers, "14.1") == "14.1"
    assert Client.pick_protocol_version(headers, "16.0") == "14.0"
    assert Client.pick_protocol_version([], "14.0") == "14.0"
  end

  test "QQ Exmail prefers 14.0 and plain query mode" do
    settings = %{host: "ex.exmail.qq.com", protocol_version: "14.1"}
    assert Client.preferred_protocol_version(settings) == "14.0"
    assert Client.query_mode_order(settings) == [:plain, :base64]
    assert Client.qq_exmail_host?("ex.exmail.qq.com")
    refute Client.qq_exmail_host?("mail.contoso.com")

    assert Client.query_mode_order(%{host: "ex.exmail.qq.com", force_query_mode: :base64}) ==
             [:base64, :plain]
  end

  test "provision request WBXML includes DeviceInformation for 14.1" do
    Req.Test.stub(EASClientProtocol, fn conn ->
      case conn.method do
        "OPTIONS" ->
          conn
          |> Plug.Conn.put_resp_header("ms-asprotocolversions", "14.1")
          |> Plug.Conn.send_resp(200, "")

        "POST" ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          assert {:ok, root} = WBXML.decode(body)
          assert elem(root, 1) == "Provision"
          assert WBXML.find(root, "DeviceInformation")
          assert WBXML.text(WBXML.find(root, "Model")) == "iPhone"
          assert conn.query_string =~ "User=user@ex.com"
          assert conn.query_string =~ "Cmd=Provision"
          refute conn.query_string =~ "%40"

          resp =
            WBXML.encode(
              {14, "Provision",
               [
                 {14, "Status", ["1"]},
                 {14, "Policies",
                  [
                    {14, "Policy",
                     [
                       {14, "PolicyType", ["MS-EAS-Provisioning-WBXML"]},
                       {14, "Status", ["2"]}
                     ]}
                  ]}
               ]}
            )

          conn
          |> Plug.Conn.put_resp_header("content-type", "application/vnd.ms-sync.wbxml")
          |> Plug.Conn.send_resp(200, resp)
      end
    end)

    settings = %{
      host: "eas.test",
      port: 443,
      path: "/Microsoft-Server-ActiveSync",
      username: "user@ex.com",
      password: "secret",
      device_id: "ApplABCD1234EFGH",
      device_type: "iPhone",
      protocol_version: "14.1",
      emit_activity: false,
      req_options: [plug: {Req.Test, EASClientProtocol}]
    }

    assert {:ok, conn} = Client.connect(settings)
    assert {:ok, _conn, %{policy_key: "0"}} = Client.provision(conn)
  end

  test "provision 14.0 omits DeviceInformation and sends Settings instead" do
    Req.Test.stub(EASClientProtocol140, fn conn ->
      case {conn.method, conn.query_string} do
        {"OPTIONS", _} ->
          conn
          |> Plug.Conn.put_resp_header("ms-asprotocolversions", "14.0")
          |> Plug.Conn.send_resp(200, "")

        {"POST", query} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          assert {:ok, root} = WBXML.decode(body)

          cond do
            String.contains?(query, "Cmd=Provision") or match_base64_cmd?(query, 20) ->
              assert elem(root, 1) == "Provision"
              refute WBXML.find(root, "DeviceInformation")

              resp =
                WBXML.encode(
                  {14, "Provision",
                   [
                     {14, "Status", ["1"]},
                     {14, "Policies",
                      [
                        {14, "Policy",
                         [
                           {14, "PolicyType", ["MS-EAS-Provisioning-WBXML"]},
                           {14, "Status", ["2"]}
                         ]}
                      ]}
                   ]}
                )

              conn
              |> Plug.Conn.put_resp_header("content-type", "application/vnd.ms-sync.wbxml")
              |> Plug.Conn.send_resp(200, resp)

            String.contains?(query, "Cmd=Settings") or match_base64_cmd?(query, 17) ->
              assert elem(root, 1) == "Settings"
              assert WBXML.find(root, "DeviceInformation")
              assert WBXML.text(WBXML.find(root, "Model")) == "iPhone"

              resp =
                WBXML.encode(
                  {18, "Settings",
                   [
                     {18, "Status", ["1"]},
                     {18, "DeviceInformation", [{18, "Status", ["1"]}]}
                   ]}
                )

              conn
              |> Plug.Conn.put_resp_header("content-type", "application/vnd.ms-sync.wbxml")
              |> Plug.Conn.send_resp(200, resp)

            true ->
              Plug.Conn.send_resp(conn, 500, "unexpected")
          end
      end
    end)

    settings = %{
      host: "eas.test",
      port: 443,
      path: "/Microsoft-Server-ActiveSync",
      username: "user@ex.com",
      password: "secret",
      device_id: "ApplABCD1234EFGH",
      device_type: "iPhone",
      protocol_version: "14.0",
      emit_activity: false,
      req_options: [plug: {Req.Test, EASClientProtocol140}]
    }

    assert {:ok, conn} = Client.connect(settings)
    assert {:ok, _conn, %{policy_key: "0"}} = Client.provision(conn)
  end

  test "FolderSync HTTP HTML 400 yields gateway-specific error" do
    Req.Test.stub(EASClientProtocolHtml400, fn conn ->
      case conn.method do
        "OPTIONS" ->
          conn
          |> Plug.Conn.put_resp_header("ms-asprotocolversions", "14.1")
          |> Plug.Conn.send_resp(200, "")

        "POST" ->
          html = "<HTML><HEAD><TITLE>400 Bad Request</TITLE></HEAD><BODY></BODY></HTML>"

          conn
          |> Plug.Conn.put_resp_content_type("text/html")
          |> Plug.Conn.send_resp(400, html)
      end
    end)

    settings = %{
      host: "eas.test",
      port: 443,
      path: "/Microsoft-Server-ActiveSync",
      username: "user@ex.com",
      password: "secret",
      device_id: "ApplABCD1234EFGH",
      device_type: "iPhone",
      protocol_version: "14.1",
      emit_activity: false,
      req_options: [plug: {Req.Test, EASClientProtocolHtml400}]
    }

    assert {:ok, conn} = Client.connect(settings)
    assert {:error, %Error{message: message}} = Client.folder_sync(conn, "0")
    assert message =~ "FolderSync"
    assert message =~ "gateway rejected"
  end

  defp match_base64_cmd?(query, command_code) when is_binary(query) do
    case Base.decode64(query) do
      {:ok, <<_ver, ^command_code, _rest::binary>>} -> true
      _ -> false
    end
  end
end
