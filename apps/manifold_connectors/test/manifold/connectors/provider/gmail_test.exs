defmodule Manifold.Connectors.Provider.GmailTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Manifold.Connectors.Provider
  alias Manifold.Connectors.GmailScopes
  alias Manifold.Connectors.Provider.Gmail

  @config [
    client_id: "gmail-client",
    client_secret: "gmail-secret",
    token_url: "https://oauth.gmail.test/token",
    userinfo_url: "https://openid.gmail.test/v1/userinfo",
    base_url: "https://gmail.test",
    req_options: [plug: {Req.Test, Gmail}]
  ]

  test "exchanges an authorization code with PKCE" do
    Req.Test.expect(Gmail, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/token"

      assert Plug.Conn.get_req_header(conn, "content-type") == [
               "application/x-www-form-urlencoded"
             ]

      {:ok, body, conn} = Plug.Conn.read_body(conn)

      assert URI.decode_query(body) == %{
               "client_id" => "gmail-client",
               "client_secret" => "gmail-secret",
               "code" => "authorization-code",
               "code_verifier" => "pkce-verifier",
               "grant_type" => "authorization_code",
               "redirect_uri" => "https://mail.example.test/oauth/gmail/callback"
             }

      Req.Test.json(conn, %{
        "access_token" => "access-token",
        "refresh_token" => "refresh-token",
        "expires_in" => 3_600,
        "scope" => "openid https://www.googleapis.com/auth/gmail.readonly",
        "token_type" => "Bearer"
      })
    end)

    now = ~U[2026-07-29 01:00:00Z]

    assert {:ok,
            %Provider.Token{
              access_token: "access-token",
              refresh_token: "refresh-token",
              expires_at: ~U[2026-07-29 02:00:00Z],
              scopes: ["openid", "https://www.googleapis.com/auth/gmail.readonly"]
            }} =
             Gmail.exchange_code(
               "authorization-code",
               "pkce-verifier",
               "https://mail.example.test/oauth/gmail/callback",
               @config,
               now: now
             )
  end

  test "uses trusted callback scopes when the authorization response omits scope" do
    for required_scopes <- [
          [GmailScopes.send()],
          [GmailScopes.read(), GmailScopes.send()]
        ] do
      Req.Test.expect(Gmail, fn conn ->
        Req.Test.json(conn, %{
          "access_token" => "access-token",
          "refresh_token" => "refresh-token",
          "expires_in" => 3_600,
          "token_type" => "Bearer"
        })
      end)

      assert {:ok, %Provider.Token{scopes: ^required_scopes}} =
               Gmail.exchange_code(
                 "authorization-code",
                 "pkce-verifier",
                 "https://mail.example.test/oauth/gmail/callback",
                 @config,
                 now: ~U[2026-07-29 01:00:00Z],
                 required_scopes: required_scopes
               )
    end
  end

  test "prefers provider response scopes over the callback fallback" do
    Req.Test.expect(Gmail, fn conn ->
      Req.Test.json(conn, %{
        "access_token" => "access-token",
        "refresh_token" => "refresh-token",
        "expires_in" => 3_600,
        "scope" => GmailScopes.read(),
        "token_type" => "Bearer"
      })
    end)

    assert {:ok, %Provider.Token{scopes: [scope]}} =
             Gmail.exchange_code(
               "authorization-code",
               "pkce-verifier",
               "https://mail.example.test/oauth/gmail/callback",
               @config,
               now: ~U[2026-07-29 01:00:00Z],
               required_scopes: ["attacker-supplied-scope"]
             )

    assert scope == GmailScopes.read()
  end

  test "refreshes access without inventing a replacement refresh token" do
    Req.Test.expect(Gmail, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      assert URI.decode_query(body) == %{
               "client_id" => "gmail-client",
               "client_secret" => "gmail-secret",
               "grant_type" => "refresh_token",
               "refresh_token" => "stored-refresh-token"
             }

      Req.Test.json(conn, %{
        "access_token" => "refreshed-access-token",
        "expires_in" => 1_800,
        "scope" => "https://www.googleapis.com/auth/gmail.readonly"
      })
    end)

    assert {:ok,
            %Provider.Token{
              access_token: "refreshed-access-token",
              refresh_token: nil,
              expires_at: ~U[2026-07-29 01:30:00Z],
              scopes: ["https://www.googleapis.com/auth/gmail.readonly"]
            }} =
             Gmail.refresh_token(
               "stored-refresh-token",
               @config,
               now: ~U[2026-07-29 01:00:00Z]
             )
  end

  test "loads the stable OpenID subject and current email identity" do
    Req.Test.expect(Gmail, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/v1/userinfo"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer access-token"]

      Req.Test.json(conn, %{
        "sub" => "google-subject-91234",
        "email" => "Person@Example.COM"
      })
    end)

    assert {:ok,
            %Provider.Identity{
              id: "google-subject-91234",
              email_address: "Person@Example.COM"
            }} = Gmail.identity("access-token", @config, [])
  end

  test "freezes the profile history ID before the initial mailbox scan" do
    Req.Test.expect(Gmail, fn conn ->
      Req.Test.json(conn, %{"emailAddress" => "person@example.com", "historyId" => "1000"})
    end)

    assert {:ok,
            [
              %Provider.SyncCursor{
                scope: "mailbox",
                phase: "initial",
                bootstrap_cursor: "1000",
                page_cursor: nil,
                committed_cursor: nil
              }
            ]} = Gmail.initial_cursors("access-token", @config, [])
  end

  test "pages the initial message listing and keeps the frozen history anchor" do
    Req.Test.expect(Gmail, 2, fn conn ->
      query = URI.decode_query(conn.query_string)

      assert conn.request_path == "/gmail/v1/users/me/messages"
      assert query["includeSpamTrash"] == "true"
      assert query["maxResults"] == "500"

      case query["pageToken"] do
        nil ->
          Req.Test.json(conn, %{
            "messages" => [
              %{"id" => "message-1", "threadId" => "thread-1"},
              %{"id" => "message-2", "threadId" => "thread-2"}
            ],
            "nextPageToken" => "page-2",
            "resultSizeEstimate" => 3
          })

        "page-2" ->
          Req.Test.json(conn, %{
            "messages" => [%{"id" => "message-3", "threadId" => "thread-3"}]
          })
      end
    end)

    cursor = %Provider.SyncCursor{
      scope: "mailbox",
      phase: "initial",
      bootstrap_cursor: "1000"
    }

    assert {:ok,
            %Provider.Page{
              messages: [
                %Provider.RemoteMessage{id: "message-1", thread_id: "thread-1"},
                %Provider.RemoteMessage{id: "message-2", thread_id: "thread-2"}
              ],
              cursor: %Provider.SyncCursor{
                phase: "initial",
                bootstrap_cursor: "1000",
                page_cursor: "page-2",
                committed_cursor: nil
              }
            }} = Gmail.sync_page("access-token", cursor, @config, [])

    cursor = %{cursor | page_cursor: "page-2"}

    assert {:ok,
            %Provider.Page{
              messages: [%Provider.RemoteMessage{id: "message-3", thread_id: "thread-3"}],
              cursor: %Provider.SyncCursor{
                phase: "incremental",
                bootstrap_cursor: nil,
                page_cursor: nil,
                committed_cursor: "1000"
              }
            }} = Gmail.sync_page("access-token", cursor, @config, [])
  end

  test "normalizes paginated history without duplicating generic messages" do
    Req.Test.expect(Gmail, 2, fn conn ->
      query = URI.decode_query(conn.query_string)

      assert conn.request_path == "/gmail/v1/users/me/history"
      assert query["startHistoryId"] == "1000"
      assert query["maxResults"] == "500"

      case query["pageToken"] do
        nil ->
          Req.Test.json(conn, %{
            "history" => [
              %{
                "id" => "1001",
                "messages" => [%{"id" => "generic-must-not-be-emitted"}],
                "messagesAdded" => [
                  %{
                    "message" => %{
                      "id" => "message-1",
                      "threadId" => "thread-1",
                      "labelIds" => ["INBOX", "UNREAD", "STARRED"]
                    }
                  }
                ],
                "labelsRemoved" => [
                  %{
                    "message" => %{
                      "id" => "message-2",
                      "threadId" => "thread-2",
                      "labelIds" => ["INBOX"]
                    },
                    "labelIds" => ["UNREAD"]
                  }
                ]
              }
            ],
            "nextPageToken" => "history-page-2",
            "historyId" => "1002"
          })

        "history-page-2" ->
          Req.Test.json(conn, %{
            "history" => [
              %{
                "id" => "1003",
                "labelsAdded" => [
                  %{
                    "message" => %{
                      "id" => "message-2",
                      "threadId" => "thread-2",
                      "labelIds" => ["INBOX", "STARRED"]
                    },
                    "labelIds" => ["STARRED"]
                  }
                ],
                "messagesDeleted" => [
                  %{"message" => %{"id" => "message-3", "threadId" => "thread-3"}}
                ]
              }
            ],
            "historyId" => "1003"
          })
      end
    end)

    cursor = %Provider.SyncCursor{
      scope: "mailbox",
      phase: "incremental",
      committed_cursor: "1000"
    }

    assert {:ok,
            %Provider.Page{
              messages: [
                %Provider.RemoteMessage{
                  id: "message-1",
                  labels: ["INBOX", "STARRED", "UNREAD"],
                  read?: false,
                  starred?: true
                },
                %Provider.RemoteMessage{
                  id: "message-2",
                  labels: ["INBOX"],
                  read?: true,
                  starred?: false
                }
              ],
              cursor: %Provider.SyncCursor{
                committed_cursor: "1000",
                page_cursor: "history-page-2"
              }
            }} = Gmail.sync_page("access-token", cursor, @config, [])

    cursor = %{cursor | page_cursor: "history-page-2"}

    assert {:ok,
            %Provider.Page{
              messages: [
                %Provider.RemoteMessage{
                  id: "message-2",
                  labels: ["INBOX", "STARRED"],
                  read?: true,
                  starred?: true
                },
                %Provider.RemoteMessage{id: "message-3", deleted?: true}
              ],
              cursor: %Provider.SyncCursor{
                phase: "incremental",
                committed_cursor: "1003",
                page_cursor: nil
              }
            }} = Gmail.sync_page("access-token", cursor, @config, [])
  end

  test "resets an expired history cursor with a newly frozen profile history ID" do
    Req.Test.expect(Gmail, 2, fn conn ->
      case conn.request_path do
        "/gmail/v1/users/me/history" ->
          conn
          |> Plug.Conn.put_status(404)
          |> Req.Test.json(%{"error" => %{"code" => 404, "message" => "history expired"}})

        "/gmail/v1/users/me/profile" ->
          Req.Test.json(conn, %{
            "emailAddress" => "person@example.com",
            "historyId" => "2000"
          })
      end
    end)

    cursor = %Provider.SyncCursor{
      scope: "mailbox",
      phase: "incremental",
      committed_cursor: "1000"
    }

    assert {:ok,
            %Provider.Page{
              messages: [],
              cursor: %Provider.SyncCursor{
                scope: "mailbox",
                phase: "initial",
                bootstrap_cursor: "2000",
                page_cursor: nil,
                committed_cursor: nil
              }
            }} = Gmail.sync_page("access-token", cursor, @config, [])
  end

  test "decodes unpadded base64url RAW bytes and internal date" do
    raw = "From: sender@example.net\r\nSubject: hello\r\n\r\nbody\r\n"

    Req.Test.expect(Gmail, fn conn ->
      assert conn.request_path == "/gmail/v1/users/me/messages/message-1"
      assert URI.decode_query(conn.query_string) == %{"format" => "RAW"}

      Req.Test.json(conn, %{
        "id" => "message-1",
        "threadId" => "thread-1",
        "labelIds" => ["INBOX", "STARRED"],
        "internalDate" => "1785286800000",
        "raw" => Base.url_encode64(raw, padding: false)
      })
    end)

    assert {:ok,
            %Provider.RawMessage{
              bytes: ^raw,
              received_at: ~U[2026-07-29 01:00:00.000Z],
              thread_id: "thread-1",
              labels: ["INBOX", "STARRED"],
              read?: true,
              starred?: true
            }} = Gmail.fetch_raw("access-token", "message-1", @config, [])
  end

  test "classifies retryable, reconnect, and permanent provider failures" do
    Req.Test.expect(Gmail, 4, fn conn ->
      case Process.get(:gmail_failure) do
        :rate ->
          conn
          |> Plug.Conn.put_resp_header("retry-after", "90")
          |> Plug.Conn.put_status(429)
          |> Req.Test.json(%{"error" => %{"message" => "quota details must not escape"}})

        :server ->
          conn
          |> Plug.Conn.put_status(503)
          |> Req.Test.json(%{"error" => %{"message" => "backend details must not escape"}})

        :invalid_grant ->
          conn
          |> Plug.Conn.put_status(400)
          |> Req.Test.json(%{"error" => "invalid_grant", "error_description" => "token leaked"})

        :forbidden ->
          conn
          |> Plug.Conn.put_status(403)
          |> Req.Test.json(%{
            "error" => %{
              "errors" => [%{"reason" => "domainPolicy"}],
              "message" => "policy details"
            }
          })
      end
    end)

    Process.put(:gmail_failure, :rate)

    assert {:error,
            %Provider.Error{
              class: :temporary,
              code: :rate_limited,
              retry_after_seconds: 90
            }} = Gmail.identity("secret-access-token", @config, [])

    Process.put(:gmail_failure, :server)

    assert {:error, %{class: :temporary, code: :provider_unavailable}} =
             Gmail.identity("secret-access-token", @config, [])

    Process.put(:gmail_failure, :invalid_grant)

    assert {:error, %{class: :reconnect, code: :invalid_grant}} =
             Gmail.refresh_token("secret-refresh-token", @config, [])

    Process.put(:gmail_failure, :forbidden)

    assert {:error, %{class: :permanent, code: :domain_policy}} =
             Gmail.identity("secret-access-token", @config, [])
  after
    Process.delete(:gmail_failure)
  end

  test "transport failures are temporary and errors and logs omit tokens and response bodies" do
    Req.Test.expect(Gmail, 2, fn conn ->
      case Process.get(:gmail_transport) do
        :timeout ->
          Req.Test.transport_error(conn, :timeout)

        :body ->
          conn
          |> Plug.Conn.put_status(400)
          |> Req.Test.json(%{
            "error" => %{
              "message" => "private body marker",
              "errors" => [%{"reason" => "badRequest"}]
            }
          })
      end
    end)

    log =
      capture_log(fn ->
        Process.put(:gmail_transport, :timeout)

        assert {:error, %Provider.Error{class: :temporary} = transport_error} =
                 Gmail.identity("secret-access-token", @config, [])

        Process.put(:gmail_transport, :body)

        assert {:error, %Provider.Error{class: :permanent} = response_error} =
                 Gmail.identity("secret-access-token", @config, [])

        refute inspect(transport_error) =~ "secret-access-token"
        refute inspect(response_error) =~ "secret-access-token"
        refute inspect(response_error) =~ "private body marker"
      end)

    refute log =~ "secret-access-token"
    refute log =~ "private body marker"
  after
    Process.delete(:gmail_transport)
  end
end
