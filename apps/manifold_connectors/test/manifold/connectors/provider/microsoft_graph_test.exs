defmodule Manifold.Connectors.Provider.MicrosoftGraphTest do
  use ExUnit.Case, async: true

  alias Manifold.Connectors.Provider
  alias Manifold.Connectors.Provider.MicrosoftGraph

  @now ~U[2026-07-29 08:00:00Z]
  @config [
    client_id: "graph-client",
    client_secret: "graph-secret",
    token_url: "https://login.microsoftonline.test/organizations/oauth2/v2.0/token",
    base_url: "https://graph.microsoft.test/v1.0",
    req_options: [plug: {Req.Test, MicrosoftGraph}]
  ]

  test "exchanges an authorization code with PKCE and normalizes the token" do
    Req.Test.expect(MicrosoftGraph, fn conn ->
      assert conn.method == "POST"
      assert conn.host == "login.microsoftonline.test"
      assert conn.request_path == "/organizations/oauth2/v2.0/token"

      {:ok, body, conn} = Plug.Conn.read_body(conn)

      assert Plug.Conn.Query.decode(body) == %{
               "client_id" => "graph-client",
               "client_secret" => "graph-secret",
               "code" => "authorization-code",
               "code_verifier" => "pkce-verifier",
               "grant_type" => "authorization_code",
               "redirect_uri" => "https://mail.example.test/oauth/microsoft/callback",
               "scope" => "openid profile offline_access User.Read Mail.Read"
             }

      Req.Test.json(conn, %{
        "access_token" => "access-token",
        "refresh_token" => "refresh-token",
        "expires_in" => 3600,
        "scope" => "Mail.Read User.Read offline_access openid profile"
      })
    end)

    assert {:ok,
            %Provider.Token{
              access_token: "access-token",
              refresh_token: "refresh-token",
              expires_at: ~U[2026-07-29 09:00:00Z],
              scopes: ["Mail.Read", "User.Read", "offline_access", "openid", "profile"]
            }} =
             MicrosoftGraph.exchange_code(
               "authorization-code",
               "pkce-verifier",
               "https://mail.example.test/oauth/microsoft/callback",
               @config,
               now: @now
             )
  end

  test "refresh preserves requested scopes and leaves an omitted rotated token unset" do
    Req.Test.expect(MicrosoftGraph, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      assert Plug.Conn.Query.decode(body) == %{
               "client_id" => "graph-client",
               "client_secret" => "graph-secret",
               "grant_type" => "refresh_token",
               "refresh_token" => "old-refresh-token",
               "scope" => "openid profile offline_access User.Read Mail.Read"
             }

      Req.Test.json(conn, %{
        "access_token" => "new-access-token",
        "expires_in" => 1800
      })
    end)

    assert {:ok,
            %Provider.Token{
              access_token: "new-access-token",
              refresh_token: nil,
              expires_at: ~U[2026-07-29 08:30:00Z],
              scopes: ["openid", "profile", "offline_access", "User.Read", "Mail.Read"]
            }} =
             MicrosoftGraph.refresh_token("old-refresh-token", @config, now: @now)
  end

  test "classifies invalid_grant as requiring reconnection" do
    Req.Test.expect(MicrosoftGraph, fn conn ->
      conn
      |> Plug.Conn.put_status(400)
      |> Req.Test.json(%{
        "error" => "invalid_grant",
        "error_description" => "The refresh token was revoked"
      })
    end)

    assert {:error,
            %Provider.Error{
              class: :reconnect,
              code: :invalid_grant,
              message: "Microsoft authorization must be renewed"
            }} = MicrosoftGraph.refresh_token("revoked", @config, now: @now)
  end

  test "loads the signed-in mailbox identity" do
    Req.Test.expect(MicrosoftGraph, fn conn ->
      assert_graph_request(conn, "GET", "/v1.0/me", "access-token")
      assert conn.query_string == "%24select=id%2Cmail%2CuserPrincipalName"

      Req.Test.json(conn, %{
        "id" => "azure-user-id",
        "mail" => nil,
        "userPrincipalName" => "Owner@Example.test"
      })
    end)

    assert {:ok,
            %Provider.Identity{
              id: "azure-user-id",
              email_address: "Owner@Example.test"
            }} = MicrosoftGraph.identity("access-token", @config, [])
  end

  test "resolves well-known folder IDs concurrently before starting folder synchronization" do
    test_pid = self()
    barrier_ref = make_ref()

    responses = %{
      "/v1.0/me/mailFolders/inbox" => %{
        "id" => "graph-inbox-id",
        "displayName" => "Bandeja de entrada"
      },
      "/v1.0/me/mailFolders/archive" => %{"id" => "graph-archive-id", "displayName" => "Archivio"},
      "/v1.0/me/mailFolders/deleteditems" => %{
        "id" => "graph-deleted-id",
        "displayName" => "Elementi eliminati"
      },
      "/v1.0/me/mailFolders/sentitems" => %{"id" => "graph-sent-id", "displayName" => "Gesendet"}
    }

    Req.Test.expect(MicrosoftGraph, 4, fn conn ->
      assert_graph_request(conn, "GET", conn.request_path, "access-token")
      assert conn.query_string == "%24select=id"

      send(test_pid, {:folder_lookup_started, conn.request_path, self(), barrier_ref})

      receive do
        {:release_folder_lookup, ^barrier_ref} -> :ok
      after
        2_000 -> flunk("folder lookup barrier was not released")
      end

      Req.Test.json(conn, Map.fetch!(responses, conn.request_path))
    end)

    initial_cursors =
      Task.async(fn -> MicrosoftGraph.initial_cursors("access-token", @config, []) end)

    started_lookups =
      for _index <- 1..4 do
        assert_receive {:folder_lookup_started, path, request_pid, ^barrier_ref}, 1_000
        {path, request_pid}
      end

    assert started_lookups
           |> Enum.map(&elem(&1, 0))
           |> MapSet.new() == MapSet.new(Map.keys(responses))

    Enum.each(started_lookups, fn {_path, request_pid} ->
      send(request_pid, {:release_folder_lookup, barrier_ref})
    end)

    assert {:ok,
            [
              %Provider.SyncCursor{
                scope: "folders",
                phase: "bootstrap",
                bootstrap_cursor: nil,
                page_cursor:
                  "https://graph.microsoft.test/v1.0/me/mailFolders/delta?$select=id,displayName",
                committed_cursor: nil,
                metadata: %{
                  "folder_mapping_version" => 1,
                  "folder_kinds_by_id" => %{
                    "graph-inbox-id" => "inbox",
                    "graph-archive-id" => "archive",
                    "graph-deleted-id" => "trash",
                    "graph-sent-id" => "sent"
                  }
                }
              }
            ]} = Task.await(initial_cursors)
  end

  test "treats a missing Archive well-known folder as optional" do
    ids_by_path = %{
      "/v1.0/me/mailFolders/inbox" => "graph-inbox-id",
      "/v1.0/me/mailFolders/deleteditems" => "graph-deleted-id",
      "/v1.0/me/mailFolders/sentitems" => "graph-sent-id"
    }

    Req.Test.expect(MicrosoftGraph, 4, fn conn ->
      if conn.request_path == "/v1.0/me/mailFolders/archive" do
        conn
        |> Plug.Conn.put_status(404)
        |> Req.Test.json(%{"error" => %{"code" => "ErrorFolderNotFound"}})
      else
        Req.Test.json(conn, %{"id" => Map.fetch!(ids_by_path, conn.request_path)})
      end
    end)

    assert {:ok,
            %Provider.FolderMapping{
              version: 1,
              kinds_by_id: %{
                "graph-inbox-id" => "inbox",
                "graph-deleted-id" => "trash",
                "graph-sent-id" => "sent"
              }
            }} = MicrosoftGraph.resolve_folder_mapping("access-token", @config, [])
  end

  test "rejects a missing required Inbox folder" do
    assert_required_folder_missing("/v1.0/me/mailFolders/inbox")
  end

  test "rejects a missing required Deleted Items folder" do
    assert_required_folder_missing("/v1.0/me/mailFolders/deleteditems")
  end

  test "rejects a missing required Sent Items folder" do
    assert_required_folder_missing("/v1.0/me/mailFolders/sentitems")
  end

  test "rejects blank and duplicate well-known folder IDs" do
    invalid_ids = [
      %{
        "/v1.0/me/mailFolders/inbox" => "   ",
        "/v1.0/me/mailFolders/archive" => "graph-archive-id",
        "/v1.0/me/mailFolders/deleteditems" => "graph-deleted-id",
        "/v1.0/me/mailFolders/sentitems" => "graph-sent-id"
      },
      %{
        "/v1.0/me/mailFolders/inbox" => "duplicate-id",
        "/v1.0/me/mailFolders/archive" => "graph-archive-id",
        "/v1.0/me/mailFolders/deleteditems" => "graph-deleted-id",
        "/v1.0/me/mailFolders/sentitems" => "duplicate-id"
      }
    ]

    for {ids_by_path, index} <- Enum.with_index(invalid_ids) do
      stub_name = {MicrosoftGraph, :invalid_folder_ids, index, make_ref()}
      config = Keyword.put(@config, :req_options, plug: {Req.Test, stub_name})

      Req.Test.stub(stub_name, fn conn ->
        Req.Test.json(conn, %{"id" => Map.fetch!(ids_by_path, conn.request_path)})
      end)

      assert {:error,
              %Provider.Error{
                class: :temporary,
                code: :invalid_provider_response
              }} = MicrosoftGraph.resolve_folder_mapping("access-token", config, [])
    end
  end

  test "retains the 401 reconnect classification during folder resolution" do
    assert_folder_mapping_failure(
      fn conn ->
        conn
        |> Plug.Conn.put_status(401)
        |> Req.Test.json(%{"error" => %{"code" => "InvalidAuthenticationToken"}})
      end,
      :reconnect,
      :invalid_token,
      nil
    )
  end

  test "retains 429 throttling and Retry-After during folder resolution" do
    assert_folder_mapping_failure(
      fn conn ->
        conn
        |> Plug.Conn.put_resp_header("retry-after", "45")
        |> Plug.Conn.put_status(429)
        |> Req.Test.json(%{"error" => %{"code" => "TooManyRequests"}})
      end,
      :temporary,
      :http_429,
      45
    )
  end

  test "retains the transport classification during folder resolution" do
    assert_folder_mapping_failure(
      &Req.Test.transport_error(&1, :timeout),
      :temporary,
      :transport_error,
      nil
    )
  end

  test "classifies localized and custom folders only by the resolved stable ID map" do
    next_link =
      "https://graph.microsoft.test/v1.0/me/mailFolders/delta?%24skiptoken=opaque%2Bvalue"

    Req.Test.expect(MicrosoftGraph, fn conn ->
      assert_graph_request(conn, "GET", "/v1.0/me/mailFolders/delta", "access-token")
      assert conn.query_string == "$select=id,displayName"

      Req.Test.json(conn, %{
        "value" => [
          %{"id" => "folder-inbox", "displayName" => "Bandeja de entrada"},
          %{"id" => "folder-sent", "displayName" => "Gesendet"},
          %{"id" => "folder/archive", "displayName" => "Inbox"},
          %{"id" => "folder-removed", "@removed" => %{"reason" => "deleted"}}
        ],
        "@odata.nextLink" => next_link
      })
    end)

    cursor = %Provider.SyncCursor{
      scope: "folders",
      phase: "bootstrap",
      page_cursor:
        "https://graph.microsoft.test/v1.0/me/mailFolders/delta?$select=id,displayName",
      metadata: %{
        "folder_mapping_version" => 1,
        "folder_kinds_by_id" => %{
          "folder-inbox" => "inbox",
          "folder-sent" => "sent"
        }
      }
    }

    assert {:ok,
            %Provider.Page{
              messages: [],
              cursor: %Provider.SyncCursor{
                scope: "folders",
                phase: "bootstrap",
                page_cursor: ^next_link,
                committed_cursor: nil
              },
              discovered_cursors: discovered
            }} = MicrosoftGraph.sync_page("access-token", cursor, @config, [])

    assert [
             %Provider.SyncCursor{
               scope: "folder:folder-inbox",
               phase: "bootstrap",
               metadata: %{
                 "folder_mapping_version" => 1,
                 "folder_kind" => "inbox"
               },
               page_cursor:
                 "https://graph.microsoft.test/v1.0/me/mailFolders/folder-inbox/messages/delta?$select=id,parentFolderId,conversationId,receivedDateTime,isRead,flag"
             },
             %Provider.SyncCursor{
               scope: "folder:folder-sent",
               phase: "bootstrap",
               metadata: %{
                 "folder_mapping_version" => 1,
                 "folder_kind" => "sent"
               },
               page_cursor:
                 "https://graph.microsoft.test/v1.0/me/mailFolders/folder-sent/messages/delta?$select=id,parentFolderId,conversationId,receivedDateTime,isRead,flag"
             },
             %Provider.SyncCursor{
               scope: "folder:folder/archive",
               phase: "bootstrap",
               metadata: %{
                 "folder_mapping_version" => 1,
                 "folder_kind" => "archive"
               },
               page_cursor:
                 "https://graph.microsoft.test/v1.0/me/mailFolders/folder%2Farchive/messages/delta?$select=id,parentFolderId,conversationId,receivedDateTime,isRead,flag"
             },
             %Provider.SyncCursor{
               scope: "folder:folder-removed",
               phase: "removed"
             }
           ] = discovered
  end

  test "normalizes message delta changes and commits the opaque delta link" do
    delta_link =
      "https://graph.microsoft.test/v1.0/me/mailFolders/folder-inbox/messages/delta?%24deltatoken=final%2Fopaque"

    Req.Test.expect(MicrosoftGraph, fn conn ->
      assert_graph_request(
        conn,
        "GET",
        "/v1.0/me/mailFolders/folder-inbox/messages/delta",
        "access-token"
      )

      Req.Test.json(conn, %{
        "value" => [
          %{
            "id" => "immutable-message-id",
            "conversationId" => "conversation-id",
            "parentFolderId" => "folder-inbox",
            "receivedDateTime" => "2026-07-29T07:30:00Z",
            "isRead" => false,
            "flag" => %{"flagStatus" => "flagged"}
          },
          %{
            "id" => "moved-or-removed",
            "@removed" => %{"reason" => "deleted"}
          }
        ],
        "@odata.deltaLink" => delta_link
      })
    end)

    cursor = %Provider.SyncCursor{
      scope: "folder:folder-inbox",
      phase: "bootstrap",
      metadata: %{"folder_kind" => "inbox"},
      page_cursor: "https://graph.microsoft.test/v1.0/me/mailFolders/folder-inbox/messages/delta"
    }

    assert {:ok,
            %Provider.Page{
              messages: [
                %Provider.RemoteMessage{
                  id: "immutable-message-id",
                  thread_id: "conversation-id",
                  received_at: ~U[2026-07-29 07:30:00Z],
                  folder_id: "folder-inbox",
                  folder_kind: "inbox",
                  labels: [],
                  read?: false,
                  starred?: true,
                  deleted?: false
                },
                %Provider.RemoteMessage{
                  id: "moved-or-removed",
                  folder_id: "folder-inbox",
                  folder_kind: "membership_tombstone",
                  tombstone_kind: :membership,
                  deleted?: false
                }
              ],
              cursor: %Provider.SyncCursor{
                scope: "folder:folder-inbox",
                phase: "steady",
                page_cursor: nil,
                committed_cursor: ^delta_link
              },
              discovered_cursors: []
            }} = MicrosoftGraph.sync_page("access-token", cursor, @config, [])
  end

  test "follows an opaque next link without rebuilding its query" do
    next_link =
      "https://graph.microsoft.test/v1.0/me/mailFolders/folder-inbox/messages/delta?%24skiptoken=A%2BB%2FC%3D"

    Req.Test.expect(MicrosoftGraph, fn conn ->
      assert conn.request_path == "/v1.0/me/mailFolders/folder-inbox/messages/delta"
      assert conn.query_string == "%24skiptoken=A%2BB%2FC%3D"

      Req.Test.json(conn, %{
        "value" => [],
        "@odata.deltaLink" =>
          "https://graph.microsoft.test/v1.0/me/mailFolders/folder-inbox/messages/delta?%24deltatoken=done"
      })
    end)

    cursor = %Provider.SyncCursor{
      scope: "folder:folder-inbox",
      phase: "bootstrap",
      page_cursor: next_link
    }

    assert {:ok, %Provider.Page{cursor: %{phase: "steady"}}} =
             MicrosoftGraph.sync_page("access-token", cursor, @config, [])
  end

  test "rejects continuation URLs that are not HTTPS on the configured authority" do
    for url <- [
          "http://graph.microsoft.test/v1.0/me/messages/delta",
          "https://graph.microsoft.test.attacker.example/v1.0/me/messages/delta",
          "https://attacker@graph.microsoft.test/v1.0/me/messages/delta",
          "/v1.0/me/messages/delta"
        ] do
      cursor = %Provider.SyncCursor{
        scope: "folder:folder-inbox",
        phase: "steady",
        page_cursor: url
      }

      assert {:error,
              %Provider.Error{
                class: :permanent,
                code: :invalid_cursor_url
              }} = MicrosoftGraph.sync_page("access-token", cursor, @config, [])
    end
  end

  test "requires a cursor reset for expired delta state" do
    Req.Test.expect(MicrosoftGraph, 2, fn conn ->
      case Process.get(:graph_reset_response) do
        :gone ->
          conn
          |> Plug.Conn.put_status(410)
          |> Req.Test.json(%{"error" => %{"code" => "resyncRequired"}})

        :sync_state ->
          conn
          |> Plug.Conn.put_status(400)
          |> Req.Test.json(%{
            "error" => %{
              "code" => "BadRequest",
              "innerError" => %{"code" => "syncStateNotFound"}
            }
          })
      end
    end)

    cursor = %Provider.SyncCursor{
      scope: "folder:folder-inbox",
      phase: "steady",
      page_cursor: "https://graph.microsoft.test/v1.0/me/mailFolders/folder-inbox/messages/delta",
      bootstrap_cursor: "accepted-history-anchor",
      metadata: %{
        "accepted_history" => %{"last_message_id" => "accepted-message"},
        "folder_mapping_version" => 1,
        "folder_kind" => "inbox"
      }
    }

    Process.put(:graph_reset_response, :gone)

    assert {:ok,
            %Provider.Page{
              cursor: %Provider.SyncCursor{
                scope: "folder:folder-inbox",
                phase: "bootstrap",
                bootstrap_cursor: "accepted-history-anchor",
                committed_cursor: nil,
                page_cursor:
                  "https://graph.microsoft.test/v1.0/me/mailFolders/folder-inbox/messages/delta?$select=id,parentFolderId,conversationId,receivedDateTime,isRead,flag",
                metadata: %{
                  "accepted_history" => %{"last_message_id" => "accepted-message"},
                  "folder_mapping_version" => 1,
                  "folder_kind" => "inbox",
                  "folder_mapping_refresh_required" => true
                }
              }
            }} =
             MicrosoftGraph.sync_page("access-token", cursor, @config, [])

    Process.put(:graph_reset_response, :sync_state)

    assert {:ok,
            %Provider.Page{
              cursor: %Provider.SyncCursor{
                phase: "bootstrap",
                bootstrap_cursor: "accepted-history-anchor",
                committed_cursor: nil,
                metadata: %{"folder_mapping_refresh_required" => true}
              }
            }} =
             MicrosoftGraph.sync_page("access-token", cursor, @config, [])
  after
    Process.delete(:graph_reset_response)
  end

  test "resets the folder-discovery lane without discarding accepted state" do
    Req.Test.expect(MicrosoftGraph, fn conn ->
      conn
      |> Plug.Conn.put_status(410)
      |> Req.Test.json(%{"error" => %{"code" => "resyncRequired"}})
    end)

    cursor = %Provider.SyncCursor{
      scope: "folders",
      phase: "steady",
      bootstrap_cursor: "accepted-folder-history",
      committed_cursor:
        "https://graph.microsoft.test/v1.0/me/mailFolders/delta?$deltatoken=expired",
      metadata: %{
        "accepted_history" => %{"folder_count" => 12},
        "folder_mapping_version" => 1,
        "folder_kinds_by_id" => %{"folder-inbox" => "inbox"}
      }
    }

    assert {:ok,
            %Provider.Page{
              cursor: %Provider.SyncCursor{
                scope: "folders",
                phase: "bootstrap",
                bootstrap_cursor: "accepted-folder-history",
                page_cursor:
                  "https://graph.microsoft.test/v1.0/me/mailFolders/delta?$select=id,displayName",
                committed_cursor: nil,
                metadata: %{
                  "accepted_history" => %{"folder_count" => 12},
                  "folder_mapping_version" => 1,
                  "folder_kinds_by_id" => %{"folder-inbox" => "inbox"},
                  "folder_mapping_refresh_required" => true
                }
              }
            }} = MicrosoftGraph.sync_page("access-token", cursor, @config, [])
  end

  test "rejects an untrusted continuation returned by Graph" do
    Req.Test.expect(MicrosoftGraph, fn conn ->
      Req.Test.json(conn, %{
        "value" => [],
        "@odata.nextLink" => "https://graph.microsoft.test.attacker.example/steal"
      })
    end)

    cursor = %Provider.SyncCursor{
      scope: "folder:folder-inbox",
      phase: "bootstrap",
      page_cursor: "https://graph.microsoft.test/v1.0/me/mailFolders/folder-inbox/messages/delta"
    }

    assert {:error, %Provider.Error{class: :permanent, code: :invalid_cursor_url}} =
             MicrosoftGraph.sync_page("access-token", cursor, @config, [])
  end

  test "fetches raw MIME through the message value endpoint" do
    raw = "From: sender@example.test\r\nSubject: Raw\r\n\r\nBody\r\n"

    Req.Test.expect(MicrosoftGraph, fn conn ->
      assert_graph_request(
        conn,
        "GET",
        "/v1.0/me/messages/immutable%2Fmessage%2Bid/$value",
        "access-token"
      )

      Plug.Conn.send_resp(conn, 200, raw)
    end)

    assert {:ok, %Provider.RawMessage{bytes: ^raw, received_at: nil}} =
             MicrosoftGraph.fetch_raw(
               "access-token",
               "immutable/message+id",
               @config,
               []
             )
  end

  test "classifies a raw message deleted before fetch as not found" do
    Req.Test.expect(MicrosoftGraph, fn conn ->
      conn
      |> Plug.Conn.put_status(404)
      |> Req.Test.json(%{"error" => %{"code" => "ErrorItemNotFound"}})
    end)

    assert {:error, %Provider.Error{class: :permanent, code: :not_found}} =
             MicrosoftGraph.fetch_raw("access-token", "gone", @config, [])
  end

  test "classifies retry, authorization, permanent, and transport failures" do
    Req.Test.expect(MicrosoftGraph, 5, fn conn ->
      case Process.get(:graph_failure) do
        :rate_limited ->
          conn
          |> Plug.Conn.put_resp_header("retry-after", "75")
          |> Plug.Conn.put_status(429)
          |> Req.Test.json(%{"error" => %{"code" => "TooManyRequests"}})

        :unavailable ->
          conn
          |> Plug.Conn.put_status(503)
          |> Req.Test.json(%{"error" => %{"code" => "ServiceUnavailable"}})

        :invalid_token ->
          conn
          |> Plug.Conn.put_status(401)
          |> Req.Test.json(%{"error" => %{"code" => "InvalidAuthenticationToken"}})

        :forbidden ->
          conn
          |> Plug.Conn.put_status(403)
          |> Req.Test.json(%{"error" => %{"code" => "ErrorAccessDenied"}})

        :network ->
          Req.Test.transport_error(conn, :timeout)
      end
    end)

    Process.put(:graph_failure, :rate_limited)

    assert {:error,
            %Provider.Error{
              class: :temporary,
              code: :http_429,
              retry_after_seconds: 75
            }} = MicrosoftGraph.identity("access-token", @config, [])

    Process.put(:graph_failure, :unavailable)

    assert {:error,
            %Provider.Error{
              class: :temporary,
              code: :http_503,
              retry_after_seconds: nil
            }} = MicrosoftGraph.identity("access-token", @config, [])

    Process.put(:graph_failure, :invalid_token)

    assert {:error,
            %Provider.Error{
              class: :reconnect,
              code: :invalid_token
            }} = MicrosoftGraph.identity("access-token", @config, [])

    Process.put(:graph_failure, :forbidden)

    assert {:error,
            %Provider.Error{
              class: :permanent,
              code: :http_403
            }} = MicrosoftGraph.identity("access-token", @config, [])

    Process.put(:graph_failure, :network)

    assert {:error,
            %Provider.Error{
              class: :temporary,
              code: :transport_error
            }} = MicrosoftGraph.identity("access-token", @config, [])
  after
    Process.delete(:graph_failure)
  end

  defp assert_required_folder_missing(required_path) do
    ids_by_path = %{
      "/v1.0/me/mailFolders/inbox" => "graph-inbox-id",
      "/v1.0/me/mailFolders/archive" => "graph-archive-id",
      "/v1.0/me/mailFolders/deleteditems" => "graph-deleted-id",
      "/v1.0/me/mailFolders/sentitems" => "graph-sent-id"
    }

    stub_name = {MicrosoftGraph, :required_folder_missing, required_path, make_ref()}
    config = Keyword.put(@config, :req_options, plug: {Req.Test, stub_name})

    Req.Test.stub(stub_name, fn conn ->
      if conn.request_path == required_path do
        conn
        |> Plug.Conn.put_status(404)
        |> Req.Test.json(%{"error" => %{"code" => "ErrorFolderNotFound"}})
      else
        Req.Test.json(conn, %{"id" => Map.fetch!(ids_by_path, conn.request_path)})
      end
    end)

    assert {:error,
            %Provider.Error{
              class: :permanent,
              code: :required_folder_missing
            }} = MicrosoftGraph.resolve_folder_mapping("access-token", config, [])
  end

  defp assert_folder_mapping_failure(failure_response, class, code, retry_after_seconds) do
    ids_by_path = %{
      "/v1.0/me/mailFolders/archive" => "graph-archive-id",
      "/v1.0/me/mailFolders/deleteditems" => "graph-deleted-id",
      "/v1.0/me/mailFolders/sentitems" => "graph-sent-id"
    }

    stub_name = {MicrosoftGraph, code, make_ref()}
    config = Keyword.put(@config, :req_options, plug: {Req.Test, stub_name})

    Req.Test.stub(stub_name, fn conn ->
      if conn.request_path == "/v1.0/me/mailFolders/inbox" do
        failure_response.(conn)
      else
        Req.Test.json(conn, %{"id" => Map.fetch!(ids_by_path, conn.request_path)})
      end
    end)

    assert {:error,
            %Provider.Error{
              class: ^class,
              code: ^code,
              retry_after_seconds: ^retry_after_seconds
            }} = MicrosoftGraph.resolve_folder_mapping("access-token", config, [])
  end

  defp assert_graph_request(conn, method, path, token) do
    assert conn.method == method
    assert conn.request_path == path
    assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer #{token}"]

    assert Plug.Conn.get_req_header(conn, "prefer") == [
             "IdType=\"ImmutableId\", odata.maxpagesize=100"
           ]
  end
end
