defmodule Manifold.Connectors.DAV.ClientTest do
  use ExUnit.Case, async: true
  alias Manifold.Connectors.DAV.Client
  @credentials %{apple_id: "apple@example.test", app_password: "test-app-secret"}
  @base "https://contacts.icloud.com/book/"

  test "discovery follows principal/home and namespace-qualified collections" do
    transport = fn :propfind, url, headers, body ->
      assert List.keyfind(headers, "authorization", 0) ==
               {"authorization", "Basic " <> Base.encode64("apple@example.test:test-app-secret")}

      data =
        case url do
          "https://contacts.icloud.com/" ->
            response(
              "/",
              "<d:current-user-principal><d:href>/principal/</d:href></d:current-user-principal>"
            )

          "https://contacts.icloud.com/principal/" ->
            response(
              "/principal/",
              "<c:addressbook-home-set><d:href>/homes/</d:href></c:addressbook-home-set>"
            )

          "https://contacts.icloud.com/homes/" ->
            assert body =~ "resourcetype"

            response("/homes/", "<d:resourcetype><d:collection/></d:resourcetype>") <>
              response(
                "/homes/book/",
                "<d:resourcetype><d:collection/><c:addressbook/></d:resourcetype><d:displayname>Friends</d:displayname>"
              )
        end

      ok(multistatus(data))
    end

    assert {:ok, [%{href: "https://contacts.icloud.com/homes/book/", name: "Friends"}]} =
             Client.discover(@credentials, "contacts", transport: transport)
  end

  test "full snapshot retains unchanged href identities and reads changed resources" do
    transport = fn method, url, _, _ ->
      case {method, url} do
        {:propfind, @base} ->
          ok(
            multistatus(
              root() <>
                response("one.vcf", "<d:getetag>one</d:getetag>") <>
                response("two.vcf", "<d:getetag>two</d:getetag>")
            )
          )

        {:get, "https://contacts.icloud.com/book/two.vcf"} ->
          {:ok, %{status: 200, headers: %{"etag" => ["two"]}, body: "BEGIN:VCARD\nEND:VCARD"}}
      end
    end

    assert {:ok, %{mode: :full, entries: entries, deleted: [], sync_token: "token"}} =
             Client.sync_collection(%{href: @base, sync_token: nil}, @credentials,
               transport: transport,
               existing_etags: %{(@base <> "one.vcf") => "one"}
             )

    assert [
             %{href: @base <> "one.vcf", etag: "one", content: nil},
             %{href: @base <> "two.vcf", content: "BEGIN:VCARD\nEND:VCARD"}
           ] = entries
  end

  test "sync-token delta records valid deletions and changed data" do
    transport = fn method, _, _, body ->
      case method do
        :report ->
          assert body =~ "<d:sync-token>old&amp;token</d:sync-token>"

          ok(
            multistatus(
              "<d:response><d:href>gone.vcf</d:href><d:status>HTTP/1.1 404 Not Found</d:status></d:response>" <>
                response("new.vcf", "<d:getetag>new</d:getetag>"),
              "next"
            )
          )

        :get ->
          {:ok, %{status: 200, body: "new-vcard", headers: %{}}}
      end
    end

    assert {:ok,
            %{
              mode: :delta,
              deleted: [@base <> "gone.vcf"],
              entries: [%{content: "new-vcard"}],
              sync_token: "next"
            }} =
             Client.sync_collection(%{href: @base, sync_token: "old&token"}, @credentials,
               transport: transport
             )
  end

  test "invalid synchronization token falls back to a validated full snapshot" do
    transport = fn method, _, _, _ ->
      case method do
        :report ->
          {:ok,
           %{
             status: 403,
             body: "<d:error xmlns:d=\"DAV:\"><d:valid-sync-token/></d:error>",
             headers: %{}
           }}

        :propfind ->
          ok(multistatus(root()))
      end
    end

    assert {:ok, %{mode: :full, entries: []}} =
             Client.sync_collection(%{href: @base, sync_token: "invalid"}, @credentials,
               transport: transport
             )
  end

  test "unsupported synchronization REPORT falls back to ETag listing" do
    transport = fn method, _, _, _ ->
      case method do
        :report -> {:ok, %{status: 405, body: "", headers: %{}}}
        :propfind -> ok(multistatus(root()))
      end
    end

    assert {:ok, %{mode: :full}} =
             Client.sync_collection(%{href: @base, sync_token: "old"}, @credentials,
               transport: transport
             )
  end

  test "empty discovery multistatus cannot delete previously discovered collections" do
    transport = fn _, url, _, _ ->
      body =
        case url do
          "https://contacts.icloud.com/" ->
            response(
              "/",
              "<d:current-user-principal><d:href>/principal/</d:href></d:current-user-principal>"
            )

          "https://contacts.icloud.com/principal/" ->
            response(
              "/principal/",
              "<c:addressbook-home-set><d:href>/homes/</d:href></c:addressbook-home-set>"
            )

          "https://contacts.icloud.com/homes/" ->
            ""
        end

      ok(multistatus(body))
    end

    assert {:error, :incomplete_snapshot} =
             Client.discover(@credentials, :contacts, transport: transport)
  end

  test "Retry-After HTTP dates defer synchronization" do
    date =
      DateTime.utc_now() |> DateTime.add(1800) |> Calendar.strftime("%a, %d %b %Y %H:%M:%S GMT")

    transport = fn _, _, _, _ ->
      {:ok, %{status: 429, body: "", headers: %{"retry-after" => [date]}}}
    end

    assert {:error, {:rate_limited, seconds}} =
             Client.discover(@credentials, :contacts, transport: transport)

    assert seconds in 1798..1800
  end

  test "missing self-response, failed propstats, missing ETags and failed GET refuse snapshots" do
    for data <- [
          "",
          response("one.vcf", "<d:getetag>one</d:getetag>"),
          root() <> response("one.vcf", ""),
          root() <>
            "<d:response><d:href>one.vcf</d:href><d:status>HTTP/1.1 500 Failed</d:status></d:response>"
        ] do
      assert {:error, :incomplete_snapshot} =
               Client.sync_collection(%{href: @base, sync_token: nil}, @credentials,
                 transport: fn _, _, _, _ -> ok(multistatus(data)) end
               )
    end

    transport = fn method, _, _, _ ->
      if method == :propfind,
        do: ok(multistatus(root() <> response("one.vcf", "<d:getetag>one</d:getetag>"))),
        else: {:ok, %{status: 404, body: "", headers: %{}}}
    end

    assert {:error, :incomplete_snapshot} =
             Client.sync_collection(%{href: @base, sync_token: nil}, @credentials,
               transport: transport
             )
  end

  test "untrusted redirect is refused before credentials are dispatched to destination" do
    transport = fn _, url, _, _ ->
      send(self(), {:dispatch, url})

      {:ok,
       %{status: 302, body: "", headers: %{"location" => ["https://attacker.example/secret"]}}}
    end

    assert {:error, :untrusted_url} =
             Client.discover(@credentials, "contacts", transport: transport)

    assert_received {:dispatch, "https://contacts.icloud.com/"}
    refute_received {:dispatch, "https://attacker.example/secret"}
  end

  test "authorization and throttling errors never expose remote response bodies" do
    for {status, expected} <- [{401, :unauthorized}, {429, {:rate_limited, 123}}] do
      transport = fn _, _, _, _ ->
        {:ok,
         %{status: status, body: "secret-remote-error", headers: %{"retry-after" => ["123"]}}}
      end

      assert {:error, ^expected} = Client.discover(@credentials, :contacts, transport: transport)
    end
  end

  test "oversized fake response and duplicate resource identities are rejected" do
    assert {:error, :response_limit} =
             Client.discover(@credentials, :contacts,
               transport: fn _, _, _, _ -> ok(String.duplicate("a", 8 * 1024 * 1024 + 1)) end
             )

    data =
      root() <>
        response("one.vcf", "<d:getetag>one</d:getetag>") <>
        response("one.vcf", "<d:getetag>one</d:getetag>")

    assert {:error, :incomplete_snapshot} =
             Client.sync_collection(%{href: @base, sync_token: nil}, @credentials,
               transport: fn _, _, _, _ -> ok(multistatus(data)) end
             )
  end

  defp root,
    do:
      response(
        @base,
        "<d:resourcetype><d:collection/></d:resourcetype><d:sync-token>token</d:sync-token>"
      )

  defp response(href, props),
    do:
      "<d:response><d:href>#{href}</d:href><d:propstat><d:prop>#{props}</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>"

  defp multistatus(body, token \\ nil),
    do:
      "<d:multistatus xmlns:d=\"DAV:\" xmlns:c=\"urn:ietf:params:xml:ns:carddav\">#{body}#{if token, do: "<d:sync-token>#{token}</d:sync-token>", else: ""}</d:multistatus>"

  defp ok(body), do: {:ok, %{status: 207, body: body, headers: %{}}}
end
