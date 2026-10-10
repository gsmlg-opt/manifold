defmodule Manifold.Connectors.DAV.RegionalDiscoveryTest do
  use ExUnit.Case, async: true
  alias Manifold.Connectors.DAV.{Client, URL}

  @credentials %{apple_id: "apple@example.test", app_password: "test-app-secret"}
  @global "https://contacts.icloud.com/"
  @regional "https://contacts.icloud.com.cn/"
  @home "https://p205-contacts.icloud.com.cn/homes/"
  @card "urn:ietf:params:xml:ns:carddav"
  @cal "urn:ietf:params:xml:ns:caldav"

  test "China DAV URLs retain the exact Apple host and HTTPS restrictions" do
    for host <- ["contacts", "caldav", "p205-contacts", "p205-caldav"] do
      url = "https://#{host}.icloud.com.cn/book/"
      assert {:ok, ^url} = URL.validate(url)
    end

    for url <- [
          "https://contacts.icloud.com.cn.evil.test/x",
          "https://evilicloud.com.cn/x",
          "https://www.icloud.com.cn/x",
          "https://p205-contacts.icloud.com.cn./x",
          "http://contacts.icloud.com.cn/x",
          "https://user:pass@contacts.icloud.com.cn/x",
          "https://contacts.icloud.com.cn:444/x",
          "https://contacts.icloud.com.cn/x?token=secret",
          "https://contacts.icloud.com.cn/x#fragment"
        ] do
      assert {:error, :untrusted_url} = URL.validate(url)
    end
  end

  test "global calendar discovery accepts an advertised China home" do
    home = "https://p205-caldav.icloud.com.cn/homes/"

    transport = fn :propfind, url, _, _ ->
      send(self(), {:dispatch, url})
      discovery_response(url, home, @cal, "calendar-home-set", "calendar")
    end

    assert {:ok, [%{href: href}]} =
             Client.discover(@credentials, :calendars, transport: transport)

    assert href == home <> "book/"
    assert_received {:dispatch, "https://caldav.icloud.com/"}
    assert_received {:dispatch, "https://caldav.icloud.com/principal/"}
    assert_received {:dispatch, ^home}
    refute_received {:dispatch, _}
  end

  test "a nonexistent global contacts shard restarts discovery at the China root" do
    global_home = "https://p205-contacts.icloud.com/homes/"

    transport = fn :propfind, url, headers, _ ->
      send(self(), {:dispatch, url})

      assert List.keyfind(headers, "authorization", 0) ==
               {"authorization", "Basic " <> Base.encode64("apple@example.test:test-app-secret")}

      cond do
        url == global_home ->
          {:error, :nxdomain}

        URI.parse(url).host in ["contacts.icloud.com.cn", "p205-contacts.icloud.com.cn"] ->
          discovery_response(url, @home, @card, "addressbook-home-set", "addressbook")

        true ->
          discovery_response(url, global_home, @card, "addressbook-home-set", "addressbook")
      end
    end

    assert {:ok, [%{href: @home <> "book/"}]} =
             Client.discover(@credentials, :contacts, transport: transport)

    for url <- [
          @global,
          @global <> "principal/",
          global_home,
          @regional,
          @regional <> "principal/",
          @home
        ] do
      assert_received {:dispatch, ^url}
    end

    refute_received {:dispatch, _}
  end

  test "calendar discovery excludes known task-only calendars and retains event or unknown sets" do
    home = "https://p205-caldav.icloud.com.cn/homes/"

    transport = fn :propfind, url, _, _ ->
      if url == home do
        collections =
          Enum.map_join(
            [
              {"tasks", ["VTODO"]},
              {"journals", ["VJOURNAL"]},
              {"empty", []},
              {"events", ["VEVENT"]},
              {"mixed", ["VEVENT", "VTODO"]},
              {"unknown", nil}
            ],
            fn {name, components} ->
              capability =
                if components do
                  "<p:supported-calendar-component-set>" <>
                    Enum.map_join(components, &"<p:comp name=\"#{&1}\"/>") <>
                    "</p:supported-calendar-component-set>"
                else
                  ""
                end

              response(
                home <> name <> "/",
                "<d:resourcetype><d:collection/><p:calendar/></d:resourcetype>" <> capability
              )
            end
          )

        {:ok,
         %{
           status: 207,
           headers: %{},
           body:
             "<d:multistatus xmlns:d=\"DAV:\" xmlns:p=\"#{@cal}\">" <>
               response(home, "<d:resourcetype><d:collection/></d:resourcetype>") <>
               collections <> "</d:multistatus>"
         }}
      else
        discovery_response(url, home, @cal, "calendar-home-set", "calendar")
      end
    end

    assert {:ok, collections} =
             Client.discover(@credentials, :calendars, transport: transport)

    assert Enum.map(collections, & &1.href) ==
             Enum.map(["events", "mixed", "unknown"], &(home <> &1 <> "/"))
  end

  test "regional DNS failure ends discovery after a single fallback" do
    transport = fn :propfind, url, _, _ ->
      send(self(), {:dispatch, url})
      {:error, :nxdomain}
    end

    assert {:error, :nxdomain} =
             Client.discover(@credentials, :contacts, transport: transport)

    assert_received {:dispatch, @global}
    assert_received {:dispatch, @regional}
    refute_received {:dispatch, _}
  end

  test "authentication, throttling and ordinary transport errors do not switch region" do
    for {result, expected} <- [
          {{:ok, %{status: 401, headers: %{}, body: "private"}}, :unauthorized},
          {{:ok, %{status: 429, headers: %{"retry-after" => ["123"]}, body: "private"}},
           {:rate_limited, 123}},
          {{:error, :transport_failure}, :transport_failure},
          {{:error, :timeout}, :timeout}
        ] do
      transport = fn :propfind, url, _, _ ->
        send(self(), {:dispatch, url})
        result
      end

      assert {:error, ^expected} =
               Client.discover(@credentials, :contacts, transport: transport)

      assert_received {:dispatch, @global}
      refute_received {:dispatch, _}
    end
  end

  test "a hostile China home is rejected before authenticated collection dispatch" do
    hostile = "https://p205-contacts.icloud.com.cn.evil.test/homes/"

    transport = fn :propfind, url, _, _ ->
      send(self(), {:dispatch, url})
      discovery_response(url, hostile, @card, "addressbook-home-set", "addressbook")
    end

    assert {:error, :untrusted_url} =
             Client.discover(@credentials, :contacts, transport: transport)

    assert_received {:dispatch, @global}
    assert_received {:dispatch, @global <> "principal/"}
    refute_received {:dispatch, _}
  end

  test "fallback discovery rejects an untrusted redirect before dispatching credentials" do
    transport = fn :propfind, url, _, _ ->
      send(self(), {:dispatch, url})

      case url do
        @global ->
          {:error, :nxdomain}

        @regional ->
          {:ok,
           %{
             status: 302,
             body: "",
             headers: %{"location" => ["https://contacts.icloud.com.cn.evil.test/"]}
           }}
      end
    end

    assert {:error, :untrusted_url} =
             Client.discover(@credentials, :contacts, transport: transport)

    assert_received {:dispatch, @global}
    assert_received {:dispatch, @regional}
    refute_received {:dispatch, _}
  end

  defp discovery_response(url, home, namespace, home_property, collection_type) do
    body =
      case URI.parse(url).path do
        "/" ->
          response(
            "/",
            "<d:current-user-principal><d:href>/principal/</d:href></d:current-user-principal>"
          )

        "/principal/" ->
          response(
            "/principal/",
            "<p:#{home_property}><d:href>#{home}</d:href></p:#{home_property}>"
          )

        "/homes/" ->
          response(home, "<d:resourcetype><d:collection/></d:resourcetype>") <>
            response(
              home <> "book/",
              "<d:resourcetype><d:collection/><p:#{collection_type}/></d:resourcetype>"
            )
      end

    {:ok,
     %{
       status: 207,
       headers: %{},
       body: "<d:multistatus xmlns:d=\"DAV:\" xmlns:p=\"#{namespace}\">#{body}</d:multistatus>"
     }}
  end

  defp response(href, props),
    do:
      "<d:response><d:href>#{href}</d:href><d:propstat><d:prop>#{props}</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>"
end
