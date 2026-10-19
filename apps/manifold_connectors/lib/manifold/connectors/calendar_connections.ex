defmodule Manifold.Connectors.CalendarConnections do
  @moduledoc "Calendar-owned provider credentials and authorization, independent of mailboxes."
  import Ecto.Query
  alias Manifold.Connectors.{Crypto, ProviderConfig, ProviderSettings}
  alias Manifold.Connectors.Schema.CalendarOAuthTransaction
  alias Manifold.Data.Schema.{CalendarConnection, CalendarBinding}
  alias Manifold.Core.HTTPClient
  alias Manifold.Repo

  @scopes ~w(openid email https://www.googleapis.com/auth/calendar.events https://www.googleapis.com/auth/calendar.calendarlist.readonly)
  @public ~w(id provider remote_identity identity_verified_at display_name status generation scopes expires_at legacy_connection_id provider_metadata inserted_at updated_at)a

  def list do
    Repo.all(
      from c in CalendarConnection,
        order_by: [asc: c.display_name, asc: c.id],
        select: struct(c, ^@public)
    )
  end

  def discover(id, opts \\ []) do
    with %CalendarConnection{} = connection <- lookup(id),
         true <- connection.status == "active" || {:error, :reconnect_required} do
      adapter(connection.provider).discover(connection, opts)
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  def start_google_authorization(opts \\ []) do
    with {:ok, resolved} <- ProviderConfig.fetch("gmail"),
         redirect when is_binary(redirect) <- Keyword.get(opts, :redirect_uri),
         :ok <- validate_redirect(redirect),
         id = Ecto.UUID.generate(),
         state = random(),
         verifier = random(),
         {:ok, encrypted} <- Crypto.encrypt(verifier, "calendar-oauth:#{id}:verifier"),
         {:ok, _} <-
           Repo.insert(%CalendarOAuthTransaction{
             id: id,
             state_digest: digest(state),
             verifier_ciphertext: encrypted,
             redirect_uri: redirect,
             setting_id: resolved.setting_id,
             setting_version: resolved.setting_lock_version,
             expires_at: DateTime.add(DateTime.utc_now(), 600)
           }) do
      query =
        URI.encode_query(%{
          client_id: Keyword.fetch!(resolved.config, :client_id),
          redirect_uri: redirect,
          response_type: "code",
          scope: Enum.join(@scopes, " "),
          state: state,
          code_challenge: verifier |> digest() |> Base.url_encode64(padding: false),
          code_challenge_method: "S256",
          access_type: "offline",
          prompt: "consent"
        })

      {:ok,
       %{url: Keyword.fetch!(resolved.config, :authorization_url) <> "?" <> query, state: state}}
    else
      nil -> {:error, :invalid_redirect}
      error -> error
    end
  end

  def complete_google_authorization(callback, opts \\ []) do
    state = Map.get(callback, "state")
    expected = Keyword.get(opts, :expected_state)

    with true <- secure_equal?(state, expected) || {:error, :invalid_state},
         {:ok, transaction} <- consume_state(state),
         {:ok, resolved} <- ProviderConfig.fetch("gmail"),
         true <-
           same_setting?(transaction, resolved) || {:error, :provider_configuration_changed},
         {:ok, verifier} <-
           Crypto.decrypt(
             transaction.verifier_ciphertext,
             "calendar-oauth:#{transaction.id}:verifier"
           ),
         {:ok, code} <- authorization_code(callback),
         {:ok, tokens} <-
           token_request(
             resolved,
             %{
               grant_type: "authorization_code",
               code: code,
               redirect_uri: transaction.redirect_uri,
               code_verifier: verifier
             },
             opts
           ),
         :ok <- validate_scopes(tokens),
         {:ok, identity} <- google_identity(resolved, tokens["access_token"], opts),
         {:ok, connection} <- save_google(identity, tokens, resolved) do
      {:ok, public(connection)}
    else
      nil -> {:error, :authorization_denied}
      false -> {:error, :invalid_state}
      error -> error
    end
  end

  def connect_icloud(attrs, opts \\ []) do
    apple_id = value(attrs, :apple_id)
    password = value(attrs, :app_password)

    with true <-
           (is_binary(apple_id) and String.trim(apple_id) != "" and is_binary(password) and
              password != "") || {:error, :invalid_credentials},
         credentials = %{apple_id: String.trim(apple_id), app_password: password},
         {:ok, discovery} <- icloud_discovery(credentials, opts),
         {:ok, connection} <- save_icloud(discovery.identity, credentials) do
      {:ok, public(connection)}
    end
  end

  @doc "Proves a migrated connection with its own original credential, without sending writes."
  def verify_legacy(id, opts \\ []) do
    with %CalendarConnection{provider: "icloud"} = connection <- lookup(id),
         {:ok, credentials} <- decrypt_credentials(connection),
         {:ok, discovery} <- icloud_discovery(credentials, opts) do
      Repo.transaction(fn ->
        current = lock_connection!(id)
        if current.generation != connection.generation, do: Repo.rollback(:stale)

        if current.remote_identity && current.remote_identity != discovery.identity,
          do: Repo.rollback(:identity_changed)

        other =
          Repo.get_by(CalendarConnection, provider: "icloud", remote_identity: discovery.identity)

        if other && other.id != current.id, do: Repo.rollback(:identity_already_connected)

        current
        |> Ecto.Changeset.change(
          remote_identity: discovery.identity,
          identity_verified_at: DateTime.utc_now(),
          status: "active",
          provider_metadata:
            Map.put(current.provider_metadata, "identity_verification_required", false)
        )
        |> Repo.update!()
        |> public()
      end)
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  @doc "Returns short-lived plaintext only to an adapter; public connection views omit envelopes."
  def credentials(connection_or_id, opts \\ []) do
    case Keyword.get(opts, :credentials) do
      supplied when is_map(supplied) -> {:ok, supplied}
      nil -> checkout_credentials(connection_or_id, opts)
    end
  end

  def disconnect_preview(id) do
    case lookup(id) do
      nil ->
        nil

      connection ->
        bindings =
          Repo.all(from b in CalendarBinding, where: b.connection_id == ^id, order_by: b.id)

        %{
          connection_id: id,
          token: impact_token(connection, bindings),
          calendars: Enum.map(bindings, & &1.calendar_id),
          binding_ids: Enum.map(bindings, & &1.id),
          contacts_affected: false
        }
    end
  end

  def disconnect(id, confirmed_token) do
    result =
      Repo.transaction(fn ->
        connection = lock_connection!(id)

        bindings =
          Repo.all(
            from b in CalendarBinding,
              where: b.connection_id == ^id,
              order_by: b.id,
              lock: "FOR UPDATE"
          )

        unless secure_equal?(confirmed_token, impact_token(connection, bindings)),
          do: Repo.rollback(:stale_impact)

        Enum.each(bindings, fn binding ->
          if binding.state != "detached" do
            binding
            |> Ecto.Changeset.change(state: "paused", generation: binding.generation + 1)
            |> Repo.update!()
          end
        end)

        connection
        |> Ecto.Changeset.change(
          status: "paused",
          generation: connection.generation + 1,
          encrypted_credentials: nil,
          expires_at: nil,
          provider_metadata:
            Map.drop(connection.provider_metadata, ["refresh_owner", "refresh_expires_at"])
        )
        |> Repo.update!()
        |> public()
      end)

    if match?({:ok, _}, result), do: Manifold.Data.CalendarSyncState.notify()
    result
  end

  defp checkout_credentials(connection_or_id, opts) do
    id = if is_map(connection_or_id), do: connection_or_id.id, else: connection_or_id

    with %CalendarConnection{status: "active"} = connection <- lookup(id),
         {:ok, credentials} <- decrypt_credentials(connection) do
      if connection.provider == "google" do
        with {:ok, resolved} <- ProviderConfig.fetch("gmail"),
             true <-
               metadata_setting?(connection, resolved) ||
                 {:error, :provider_configuration_changed} do
          if connection.expires_at &&
               DateTime.diff(connection.expires_at, DateTime.utc_now()) <= 60,
             do: refresh_google(connection, credentials, resolved, opts),
             else: {:ok, credentials}
        end
      else
        {:ok, credentials}
      end
    else
      _ -> {:error, :reconnect_required}
    end
  end

  defp consume_state(state) do
    Repo.transaction(fn ->
      :ok = ProviderSettings.lock_provider_for_transaction("gmail")

      transaction =
        Repo.one(
          from t in CalendarOAuthTransaction,
            where: t.state_digest == ^digest(state),
            lock: "FOR UPDATE"
        )

      if is_nil(transaction) or not is_nil(transaction.consumed_at) or
           DateTime.compare(transaction.expires_at, DateTime.utc_now()) != :gt,
         do: Repo.rollback(:invalid_state)

      case ProviderSettings.validate_generation_for_transaction(
             "gmail",
             transaction.setting_id,
             transaction.setting_version
           ) do
        :ok -> :ok
        {:error, reason} -> Repo.rollback(reason)
      end

      transaction |> Ecto.Changeset.change(consumed_at: DateTime.utc_now()) |> Repo.update!()
    end)
  end

  defp token_request(resolved, parameters, opts) do
    form =
      Map.merge(parameters, %{
        client_id: Keyword.fetch!(resolved.config, :client_id),
        client_secret: Keyword.fetch!(resolved.config, :client_secret)
      })

    case HTTPClient.post(
           [
             url: Keyword.fetch!(resolved.config, :token_url),
             form: form,
             max_body_bytes: 1_048_576
           ] ++ http_options(resolved, opts)
         ) do
      {:ok, %{status: 200, body: %{"access_token" => token} = body}}
      when is_binary(token) and byte_size(token) > 0 ->
        validate_token_response(body)

      {:ok, %{body: %{"error" => "invalid_grant"}}} ->
        {:error, :reconnect_required}

      {:ok, _} ->
        {:error, :authorization_failed}

      {:error, _} ->
        {:error, :authorization_outcome_unknown}
    end
  end

  defp google_identity(resolved, token, opts) do
    case HTTPClient.request(
           [
             url: Keyword.fetch!(resolved.config, :userinfo_url),
             auth: {:bearer, token},
             max_body_bytes: 1_048_576
           ] ++ http_options(resolved, opts)
         ) do
      {:ok, %{status: 200, body: %{"sub" => subject} = body}}
      when is_binary(subject) and byte_size(subject) > 0 ->
        {:ok, body}

      _ ->
        {:error, :identity_unverified}
    end
  end

  defp save_google(identity, tokens, resolved) do
    Repo.transaction(fn ->
      :ok = ProviderSettings.lock_provider_for_transaction("gmail")

      case ProviderSettings.validate_generation_for_transaction(
             "gmail",
             resolved.setting_id,
             resolved.setting_lock_version
           ) do
        :ok -> :ok
        {:error, reason} -> Repo.rollback(reason)
      end

      current =
        Repo.one(
          from c in CalendarConnection,
            where: c.provider == "google" and c.remote_identity == ^identity["sub"],
            lock: "FOR UPDATE"
        )

      connection = current || %CalendarConnection{id: Ecto.UUID.generate(), provider: "google"}
      previous = if current, do: decrypted_or_empty(current), else: %{}
      tokens = Map.put_new(tokens, "refresh_token", previous["refresh_token"])

      unless is_binary(tokens["refresh_token"]) and tokens["refresh_token"] != "",
        do: Repo.rollback(:refresh_token_required)

      context = "calendar:#{connection.id}:credentials"
      {:ok, encrypted} = Crypto.encrypt(Jason.encode!(tokens), context)

      attrs = %{
        remote_identity: identity["sub"],
        identity_verified_at: DateTime.utc_now(),
        display_name: identity["email"] || identity["sub"],
        credential_context: context,
        encrypted_credentials: encrypted,
        scopes: granted_scopes(tokens),
        expires_at: expiry(tokens),
        status: "active",
        generation: if(current, do: current.generation + 1, else: 1),
        provider_metadata: %{
          "setting_id" => resolved.setting_id,
          "setting_version" => resolved.setting_lock_version
        }
      }

      connection |> CalendarConnection.changeset(attrs) |> Repo.insert_or_update!()
    end)
  end

  defp save_icloud(identity, credentials) do
    Repo.transaction(fn ->
      # A verified principal is the identity; user-entered email is display data.
      Ecto.Adapters.SQL.query!(Repo, "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
        "calendar-icloud:" <> identity
      ])

      existing =
        Repo.one(
          from c in CalendarConnection,
            where: c.provider == "icloud" and c.remote_identity == ^identity,
            lock: "FOR UPDATE"
        )

      connection = existing || %CalendarConnection{id: Ecto.UUID.generate(), provider: "icloud"}
      context = "calendar:#{connection.id}:credentials"
      {:ok, encrypted} = Crypto.encrypt(Jason.encode!(credentials), context)

      connection
      |> CalendarConnection.changeset(%{
        remote_identity: identity,
        identity_verified_at: DateTime.utc_now(),
        display_name: credentials.apple_id,
        encrypted_credentials: encrypted,
        credential_context: context,
        status: "active",
        generation: if(existing, do: existing.generation + 1, else: 1)
      })
      |> Repo.insert_or_update!()
    end)
  end

  defp refresh_google(connection, credentials, resolved, opts) do
    owner = Ecto.UUID.generate()

    result =
      with {:ok, leased} <- lease_refresh(connection, owner, resolved),
           {:ok, tokens} <-
             token_request(
               resolved,
               %{grant_type: "refresh_token", refresh_token: credentials.refresh_token},
               opts
             ) do
        Repo.transaction(fn ->
          validate_provider_generation!(resolved)
          current = lock_connection!(connection.id)

          if current.generation != leased.generation or
               current.provider_metadata["refresh_owner"] != owner or current.status != "active",
             do: Repo.rollback(:stale)

          unless refresh_lease_active?(current.provider_metadata),
            do: Repo.rollback(:authorization_outcome_unknown)

          # A refresh cannot silently replace the grant's field coverage.
          tokens = Map.put_new(tokens, "scope", Enum.join(current.scopes, " "))

          case validate_scopes(tokens) do
            :ok -> :ok
            {:error, reason} -> Repo.rollback(reason)
          end

          previous = decrypted_or_empty(current)
          merged = Map.merge(previous, tokens)
          {:ok, encrypted} = Crypto.encrypt(Jason.encode!(merged), current.credential_context)

          updated =
            current
            |> Ecto.Changeset.change(
              encrypted_credentials: encrypted,
              expires_at: expiry(tokens),
              provider_metadata:
                Map.drop(current.provider_metadata, ["refresh_owner", "refresh_expires_at"])
            )
            |> Repo.update!()

          {:ok, plain} = decrypt_credentials(updated)
          plain
        end)
      end

    case result do
      {:error, reason} = error ->
        clear_refresh(connection, owner, reason)
        error

      success ->
        success
    end
  end

  defp lease_refresh(connection, owner, resolved) do
    Repo.transaction(fn ->
      validate_provider_generation!(resolved)
      current = lock_connection!(connection.id)

      if current.generation != connection.generation or current.status != "active",
        do: Repo.rollback(:stale)

      metadata = current.provider_metadata

      if metadata["refresh_owner"] && refresh_lease_active?(metadata),
        do: Repo.rollback(:refresh_in_progress)

      current
      |> Ecto.Changeset.change(
        provider_metadata:
          Map.merge(metadata, %{
            "refresh_owner" => owner,
            "refresh_expires_at" => DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), 60))
          })
      )
      |> Repo.update!()
    end)
  end

  defp clear_refresh(connection, owner, reason) do
    Repo.transaction(fn ->
      current = lock_connection!(connection.id)

      if current.generation == connection.generation and current.status == "active" and
           current.provider_metadata["refresh_owner"] == owner do
        status =
          if reason in [
               :reconnect_required,
               :authorization_outcome_unknown,
               :invalid_token_response,
               :insufficient_scope
             ],
             do: "reconnect_required",
             else: current.status

        current
        |> Ecto.Changeset.change(
          status: status,
          provider_metadata:
            Map.drop(current.provider_metadata, ["refresh_owner", "refresh_expires_at"])
        )
        |> Repo.update!()
      end
    end)
  end

  defp validate_provider_generation!(resolved) do
    with :ok <- ProviderSettings.lock_provider_for_transaction("gmail"),
         :ok <-
           ProviderSettings.validate_generation_for_transaction(
             "gmail",
             resolved.setting_id,
             resolved.setting_lock_version
           ) do
      :ok
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp refresh_lease_active?(metadata) do
    with value when is_binary(value) <- metadata["refresh_expires_at"],
         {:ok, until, _} <- DateTime.from_iso8601(value) do
      DateTime.compare(until, DateTime.utc_now()) == :gt
    else
      _ -> false
    end
  end

  defp decrypt_credentials(connection) do
    with ciphertext when is_binary(ciphertext) <- connection.encrypted_credentials,
         context when is_binary(context) <- connection.credential_context,
         {:ok, raw} <- Crypto.decrypt(ciphertext, context) do
      if connection.provider_metadata["legacy_credential_format"] == "password" do
        {:ok, %{apple_id: connection.display_name, app_password: raw}}
      else
        with {:ok, map} when is_map(map) <- Jason.decode(raw) do
          if connection.provider == "google",
            do: {:ok, %{access_token: map["access_token"], refresh_token: map["refresh_token"]}},
            else: {:ok, %{apple_id: map["apple_id"], app_password: map["app_password"]}}
        end
      end
    else
      _ -> {:error, :reconnect_required}
    end
  end

  defp decrypted_or_empty(connection) do
    with ciphertext when is_binary(ciphertext) <- connection.encrypted_credentials,
         {:ok, raw} <- Crypto.decrypt(ciphertext, connection.credential_context),
         {:ok, map} when is_map(map) <- Jason.decode(raw),
         do: map,
         else: (_ -> %{})
  end

  defp icloud_discovery(credentials, opts) do
    client = Keyword.get(opts, :client, Manifold.Connectors.DAV.Client)

    case client.discover(credentials, "calendars", Keyword.put(opts, :include_identity, true)) do
      {:ok, %{identity: identity, collections: collections}}
      when is_binary(identity) and is_list(collections) ->
        {:ok, %{identity: identity, collections: collections}}

      {:error, _} = error ->
        error

      _ ->
        {:error, :identity_unverified}
    end
  end

  defp lock_connection!(id),
    do:
      Repo.one(from c in CalendarConnection, where: c.id == ^id, lock: "FOR UPDATE") ||
        Repo.rollback(:not_found)

  defp lookup(id) do
    with {:ok, uuid} <- Ecto.UUID.cast(id),
         do: Repo.get(CalendarConnection, uuid),
         else: (_ -> nil)
  end

  defp public(connection), do: struct(CalendarConnection, Map.take(connection, @public))
  defp adapter("google"), do: Manifold.Connectors.CalendarSync.Google
  defp adapter("icloud"), do: Manifold.Connectors.CalendarSync.ICloud

  defp same_setting?(transaction, resolved),
    do:
      transaction.setting_id == resolved.setting_id and
        transaction.setting_version == resolved.setting_lock_version

  defp metadata_setting?(connection, resolved),
    do:
      connection.provider_metadata["setting_id"] == resolved.setting_id and
        connection.provider_metadata["setting_version"] == resolved.setting_lock_version

  defp granted_scopes(tokens), do: String.split(tokens["scope"] || Enum.join(@scopes, " "))

  defp authorization_code(%{"code" => code}) when is_binary(code) and byte_size(code) > 0,
    do: {:ok, code}

  defp authorization_code(_), do: {:error, :authorization_denied}

  defp validate_token_response(tokens) do
    valid =
      optional_token_value?(tokens, "scope", &is_binary/1) and
        optional_token_value?(tokens, "refresh_token", &(is_binary(&1) and byte_size(&1) > 0)) and
        optional_token_value?(
          tokens,
          "token_type",
          &(is_binary(&1) and String.downcase(&1) == "bearer")
        ) and
        optional_token_value?(tokens, "expires_in", &valid_lifetime?/1)

    if valid, do: {:ok, tokens}, else: {:error, :invalid_token_response}
  end

  defp optional_token_value?(tokens, key, valid?) do
    case Map.fetch(tokens, key) do
      :error -> true
      {:ok, value} -> valid?.(value)
    end
  end

  defp valid_lifetime?(value) when is_integer(value) and value > 0,
    do: value <= 253_402_300_799 - System.system_time(:second)

  defp valid_lifetime?(_), do: false

  defp validate_scopes(tokens) do
    if Enum.all?(@scopes -- ["openid", "email"], &(&1 in granted_scopes(tokens))),
      do: :ok,
      else: {:error, :insufficient_scope}
  end

  defp expiry(tokens),
    do: DateTime.add(DateTime.utc_now(), max(0, integer(tokens["expires_in"], 3600)))

  defp integer(value, _) when is_integer(value), do: value
  defp integer(_, default), do: default

  defp http_options(resolved, opts),
    do:
      Keyword.merge(
        Keyword.get(resolved.config, :req_options, []),
        Keyword.get(opts, :http_options, [])
      )

  defp validate_redirect(uri) do
    parsed = URI.parse(uri)

    if parsed.scheme in ["http", "https"] and is_binary(parsed.host) and is_nil(parsed.fragment) and
         is_nil(parsed.userinfo),
       do: :ok,
       else: {:error, :invalid_redirect}
  end

  defp impact_token(connection, bindings),
    do:
      {connection.id, connection.generation,
       Enum.map(bindings, &{&1.id, &1.generation, &1.state})}
      |> :erlang.term_to_binary()
      |> digest()
      |> Base.url_encode64(padding: false)

  defp secure_equal?(a, b) when is_binary(a) and is_binary(b) and byte_size(a) == byte_size(b),
    do: Plug.Crypto.secure_compare(a, b)

  defp secure_equal?(_, _), do: false
  defp digest(value), do: :crypto.hash(:sha256, value)
  defp random, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
  defp value(attrs, key), do: Map.get(attrs, key, Map.get(attrs, Atom.to_string(key)))
end
