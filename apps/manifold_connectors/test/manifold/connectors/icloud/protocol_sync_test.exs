defmodule Manifold.Connectors.ICloud.ProtocolSyncTest do
  use Manifold.DataCase, async: true
  alias Manifold.Connectors.{ICloud, ICloud.Sync}
  alias Manifold.Data.Schema.{Contact, DAVCollection}

  test "queued connection traverses DAV discovery, vCard projection, ETag changes and remote deletion" do
    {:ok, account} =
      Manifold.Accounts.create_account(%{address: "test-#{Ecto.UUID.generate()}@example.test"})

    password = "aaaa-bbbb-cccc-dddd"

    {:ok, c} =
      ICloud.connect(%{
        account_id: account.id,
        apple_id: "apple@example.test",
        app_password: password,
        contacts_enabled: true,
        calendars_enabled: false
      })

    [job] = Repo.all(Oban.Job)
    assert job.worker == "Manifold.Connectors.Jobs.SyncICloud"
    assert job.args["connection_id"] == c.id

    for phase <- [1, 1, 2, :deleted] do
      transport = fn method, url, headers, _body ->
        assert {"authorization", "Basic " <> Base.encode64("apple@example.test:" <> password)} in headers

        body =
          case {method, URI.parse(url).path} do
            {:propfind, "/"} ->
              xml(
                response(
                  "/",
                  "<d:current-user-principal><d:href>/principal/</d:href></d:current-user-principal>"
                )
              )

            {:propfind, "/principal/"} ->
              xml(
                response(
                  "/principal/",
                  "<c:addressbook-home-set><d:href>/books/</d:href></c:addressbook-home-set>"
                )
              )

            {:propfind, "/books/"} ->
              xml(
                response("/books/", "<d:resourcetype><d:collection/></d:resourcetype>") <>
                  response(
                    "/books/personal/",
                    "<d:resourcetype><d:collection/><c:addressbook/></d:resourcetype><d:displayname>Personal</d:displayname>"
                  )
              )

            {:propfind, "/books/personal/"} ->
              root =
                response("/books/personal/", "<d:resourcetype><d:collection/></d:resourcetype>")

              resource =
                if phase == :deleted,
                  do: "",
                  else: response("/books/personal/ada.vcf", "<d:getetag>#{phase}</d:getetag>")

              xml(root <> resource)

            {:get, "/books/personal/ada.vcf"} ->
              "BEGIN:VCARD\r\nVERSION:3.0\r\nUID:ada\r\nFN:Ada #{phase}\r\nEMAIL:ada@example.test\r\nEND:VCARD\r\n"
          end

        {:ok, %{status: if(method == :get, do: 200, else: 207), body: body, headers: %{}}}
      end

      assert :ok =
               Sync.run(job.args["connection_id"], job.args["generation"], transport: transport)

      if phase == :deleted do
        assert Manifold.Contacts.list_contacts() == []
      else
        assert [contact] = Repo.all(Contact)
        assert contact.full_name == "Ada #{phase}"
        assert contact.uid == "ada"
        assert contact.etag == "#{phase}"
        assert contact.collection_id == hd(Repo.all(DAVCollection)).id
      end
    end

    assert hd(ICloud.list_connections()).contacts_status == "connected"
    assert hd(ICloud.list_connections()).contacts_synced_at
  end

  defp response(href, props),
    do:
      "<d:response><d:href>#{href}</d:href><d:propstat><d:prop>#{props}</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>"

  defp xml(responses),
    do:
      "<d:multistatus xmlns:d='DAV:' xmlns:c='urn:ietf:params:xml:ns:carddav'>#{responses}</d:multistatus>"
end
