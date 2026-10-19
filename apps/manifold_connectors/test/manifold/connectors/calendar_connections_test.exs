defmodule Manifold.Connectors.CalendarConnectionsTest do
  use Manifold.DataCase, async: false
  alias Manifold.Connectors.{CalendarConnections, ProviderSettings}
  alias Manifold.Data.Schema.{CalendarConnection, CalendarBinding}

  setup do
    {:ok, _} =
      ProviderSettings.put("gmail", %{client_id: "calendar-client", client_secret: "secret"})

    :ok
  end

  test "Calendar OAuth works without mailbox and never requests Gmail permission" do
    assert {:ok, started} =
             CalendarConnections.start_google_authorization(
               redirect_uri: "http://localhost/calendar/callback"
             )

    query = URI.decode_query(URI.parse(started.url).query)
    assert query["scope"] =~ "calendar.events"
    refute query["scope"] =~ "gmail"
    assert query["code_challenge_method"] == "S256"

    assert {:ok, connection} =
             CalendarConnections.complete_google_authorization(
               %{"state" => started.state, "code" => "code"},
               expected_state: started.state,
               http_options: [plug: token_plug()]
             )

    assert connection.remote_identity == "google-subject-1"
    assert connection.provider == "google"
    assert connection.encrypted_credentials == nil

    assert {:ok, %{access_token: "calendar-access"}} =
             CalendarConnections.credentials(connection.id)

    assert {:error, :invalid_state} =
             CalendarConnections.complete_google_authorization(
               %{"state" => started.state, "code" => "code"},
               expected_state: started.state,
               http_options: [plug: fn _ -> flunk("replayed token exchange") end]
             )
  end

  test "state mismatch and changed provider settings prevent token exchange" do
    {:ok, started} =
      CalendarConnections.start_google_authorization(
        redirect_uri: "http://localhost/calendar/callback"
      )

    assert {:error, :invalid_state} =
             CalendarConnections.complete_google_authorization(
               %{"state" => started.state, "code" => "code"},
               expected_state: "wrong"
             )

    {:ok, _} =
      ProviderSettings.put("gmail", %{
        client_id: "changed-client",
        client_secret: "changed-secret"
      })

    assert {:error, _} =
             CalendarConnections.complete_google_authorization(
               %{"state" => started.state, "code" => "code"},
               expected_state: started.state,
               http_options: [plug: fn _ -> flunk("stale authorization network") end]
             )
  end

  test "verified same identity reauthorization preserves binding IDs and pending data" do
    first = authorize()

    binding =
      Repo.insert!(%CalendarBinding{
        connection_id: first.id,
        remote_calendar_id: "one",
        state: "paused"
      })

    second = authorize()
    assert second.id == first.id
    assert Repo.get!(CalendarBinding, binding.id).connection_id == first.id
    assert Repo.aggregate(CalendarConnection, :count) == 1
  end

  test "disconnect validates impact and preserves Calendar data and other connections" do
    first = authorize()
    other = Repo.insert!(%CalendarConnection{provider: "icloud", status: "active"})
    {:ok, calendar} = Manifold.Calendars.create_calendar(%{name: "Local"})

    binding =
      Repo.insert!(%CalendarBinding{
        connection_id: first.id,
        calendar_id: calendar.id,
        remote_calendar_id: "one",
        state: "active"
      })

    impact = CalendarConnections.disconnect_preview(first.id)
    assert {:error, :stale_impact} = CalendarConnections.disconnect(first.id, "wrong")
    assert {:ok, _} = CalendarConnections.disconnect(first.id, impact.token)
    assert Repo.get!(CalendarBinding, binding.id).state == "paused"
    assert Repo.get!(CalendarConnection, first.id).encrypted_credentials == nil
    assert Repo.get!(CalendarConnection, other.id).status == "active"
    assert Manifold.Calendars.get_calendar(calendar.id)
  end

  test "refresh rejects provider settings changed during HTTP and releases its lease" do
    connection = expired_connection()
    before = Repo.get!(CalendarConnection, connection.id)

    plug = fn conn ->
      {:ok, _} =
        ProviderSettings.put("gmail", %{
          client_id: "rotated-client",
          client_secret: "rotated-secret"
        })

      json(conn, %{"access_token" => "late-token", "expires_in" => 3600})
    end

    assert {:error, %{reason: :provider_configuration_changed}} =
             CalendarConnections.credentials(connection.id, http_options: [plug: plug])

    after_refresh = Repo.get!(CalendarConnection, connection.id)
    assert after_refresh.encrypted_credentials == before.encrypted_credentials
    refute after_refresh.provider_metadata["refresh_owner"]
  end

  test "authorization rejects settings changed during identity verification and consumes state" do
    {:ok, started} =
      CalendarConnections.start_google_authorization(
        redirect_uri: "http://localhost/calendar/callback"
      )

    plug = fn conn ->
      if conn.method == "GET" do
        {:ok, _} =
          ProviderSettings.put("gmail", %{
            client_id: "rotated-client",
            client_secret: "rotated-secret"
          })
      end

      token_plug().(conn)
    end

    assert {:error, %{reason: :provider_configuration_changed}} = complete(started, plug)
    assert Repo.aggregate(CalendarConnection, :count) == 0

    assert {:error, :invalid_state} =
             complete(started, fn _ -> flunk("replayed authorization") end)
  end

  test "malformed OAuth token values fail closed and cannot be replayed" do
    for invalid <- [
          %{"scope" => ["https://www.googleapis.com/auth/calendar.events"]},
          %{"expires_in" => "bad"},
          %{"expires_in" => 0},
          %{"expires_in" => -1},
          %{"refresh_token" => 42},
          %{"token_type" => "Basic"}
        ] do
      {:ok, started} =
        CalendarConnections.start_google_authorization(
          redirect_uri: "http://localhost/calendar/callback"
        )

      plug = fn conn ->
        assert conn.method == "POST"

        json(
          conn,
          Map.merge(
            %{"access_token" => "access", "refresh_token" => "refresh", "expires_in" => 3600},
            invalid
          )
        )
      end

      assert {:error, :invalid_token_response} = complete(started, plug)

      assert {:error, :invalid_state} =
               complete(started, fn _ -> flunk("replayed malformed exchange") end)
    end

    assert Repo.aggregate(CalendarConnection, :count) == 0
  end

  test "invalid callback code returns an authorization error without HTTP" do
    for code <- ["", 123, %{}] do
      {:ok, started} =
        CalendarConnections.start_google_authorization(
          redirect_uri: "http://localhost/calendar/callback"
        )

      assert {:error, :authorization_denied} =
               CalendarConnections.complete_google_authorization(
                 %{"state" => started.state, "code" => code},
                 expected_state: started.state,
                 http_options: [plug: fn _ -> flunk("invalid code exchange") end]
               )
    end
  end

  test "refresh has one owner and an omitted scope preserves its verified grant" do
    connection = expired_connection()

    plug = fn conn ->
      assert {:error, :refresh_in_progress} =
               CalendarConnections.credentials(connection.id,
                 http_options: [plug: fn _ -> flunk("concurrent refresh") end]
               )

      json(conn, %{"access_token" => "refreshed", "expires_in" => 3600})
    end

    assert {:ok, %{access_token: "refreshed", refresh_token: "calendar-refresh"}} =
             CalendarConnections.credentials(connection.id, http_options: [plug: plug])

    refute Repo.get!(CalendarConnection, connection.id).provider_metadata["refresh_owner"]
  end

  test "insufficient refreshed scope releases the lease without replacing credentials" do
    connection = expired_connection()
    before = Repo.get!(CalendarConnection, connection.id)

    plug = fn conn ->
      json(conn, %{"access_token" => "limited", "scope" => "openid email", "expires_in" => 3600})
    end

    assert {:error, :insufficient_scope} =
             CalendarConnections.credentials(connection.id, http_options: [plug: plug])

    current = Repo.get!(CalendarConnection, connection.id)
    assert current.encrypted_credentials == before.encrypted_credentials
    refute current.provider_metadata["refresh_owner"]
  end

  test "an expired refresh lease cannot commit a late response" do
    connection = expired_connection()
    before = Repo.get!(CalendarConnection, connection.id)

    plug = fn conn ->
      current = Repo.get!(CalendarConnection, connection.id)

      metadata =
        Map.put(
          current.provider_metadata,
          "refresh_expires_at",
          DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), -1))
        )

      Repo.update!(Ecto.Changeset.change(current, provider_metadata: metadata))
      json(conn, %{"access_token" => "late", "expires_in" => 3600})
    end

    assert {:error, :authorization_outcome_unknown} =
             CalendarConnections.credentials(connection.id, http_options: [plug: plug])

    current = Repo.get!(CalendarConnection, connection.id)
    assert current.encrypted_credentials == before.encrypted_credentials
    assert current.status == "reconnect_required"
    refute current.provider_metadata["refresh_owner"]
  end

  test "late failed refresh cannot change a disconnected connection" do
    connection = expired_connection()

    plug = fn conn ->
      impact = CalendarConnections.disconnect_preview(connection.id)
      assert {:ok, _} = CalendarConnections.disconnect(connection.id, impact.token)
      Manifold.Core.HTTPClient.Test.transport_error(conn, :timeout)
    end

    assert {:error, :authorization_outcome_unknown} =
             CalendarConnections.credentials(connection.id, http_options: [plug: plug])

    current = Repo.get!(CalendarConnection, connection.id)
    assert current.status == "paused"
    assert current.encrypted_credentials == nil
    refute current.provider_metadata["refresh_owner"]
  end

  defp complete(started, plug) do
    CalendarConnections.complete_google_authorization(
      %{"state" => started.state, "code" => "code"},
      expected_state: started.state,
      http_options: [plug: plug]
    )
  end

  defp expired_connection do
    connection = authorize()
    current = Repo.get!(CalendarConnection, connection.id)
    Repo.update!(Ecto.Changeset.change(current, expires_at: DateTime.add(DateTime.utc_now(), -1)))
  end

  defp json(conn, body),
    do:
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(body))

  defp authorize do
    {:ok, started} =
      CalendarConnections.start_google_authorization(
        redirect_uri: "http://localhost/calendar/callback"
      )

    {:ok, connection} =
      CalendarConnections.complete_google_authorization(
        %{"state" => started.state, "code" => "code"},
        expected_state: started.state,
        http_options: [plug: token_plug()]
      )

    connection
  end

  defp token_plug do
    fn conn ->
      body =
        if conn.method == "POST",
          do: %{
            "access_token" => "calendar-access",
            "refresh_token" => "calendar-refresh",
            "expires_in" => 3600
          },
          else: %{"sub" => "google-subject-1", "email" => "calendar@example.test"}

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(body))
    end
  end
end
