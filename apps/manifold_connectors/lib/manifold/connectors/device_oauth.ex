defmodule Manifold.Connectors.DeviceOAuth do
  @moduledoc "Durable Microsoft public-client OAuth device authorizations."

  import Ecto.Query
  alias Manifold.Accounts

  alias Manifold.Connectors.{
    Crypto,
    OAuthAuthorizations,
    OAuthScopes,
    ProviderConfig,
    ProviderSettings
  }

  alias Manifold.Connectors.OAuth.Consumed
  alias Manifold.Connectors.Provider.{MicrosoftGraph, Token}
  alias Manifold.Connectors.Provider.Error, as: ProviderError
  alias Manifold.Connectors.Schema.{OAuthAuthorization, OAuthDeviceTransaction}
  alias Manifold.Core.Error
  alias Manifold.Repo

  @claim_seconds 90

  def start(account_id, purpose, opts \\ []) do
    now = now(opts)

    with {:ok, account_id} <- uuid(account_id),
         {:ok, purpose} <- purpose(purpose),
         {:ok, resolved} <- config(),
         {:ok, scopes} <- required_scopes(account_id, purpose),
         :ok <- active_account(account_id),
         {:ok, authorization} <-
           adapter(opts).request_device_code(resolved.config, provider_opts(opts, scopes)),
         id = Ecto.UUID.generate(),
         {:ok, ciphertext} <- Crypto.encrypt(authorization.device_code, context(id, account_id)) do
      transaction(fn ->
        with :ok <- generation(resolved.setting_id, resolved.setting_lock_version),
             {:ok, _account} <- Accounts.active_account_for_update(Repo, account_id) do
          Repo.insert!(%OAuthDeviceTransaction{
            id: id,
            account_id: account_id,
            purpose: Atom.to_string(purpose),
            required_scopes: scopes,
            oauth_provider_setting_id: resolved.setting_id,
            oauth_provider_setting_lock_version: resolved.setting_lock_version,
            device_code_ciphertext: ciphertext,
            user_code: authorization.user_code,
            verification_uri: authorization.verification_uri,
            expires_at: DateTime.add(now, authorization.expires_in, :second),
            interval: authorization.interval,
            next_poll_at: DateTime.add(now, authorization.interval, :second)
          })
          |> view(now)
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    else
      {:error, reason} -> {:error, normalize_error(reason)}
    end
  rescue
    _ in [DBConnection.ConnectionError, Postgrex.Error] -> {:error, database_error()}
  end

  def get(id) do
    with {:ok, id} <- uuid(id),
         %OAuthDeviceTransaction{} = row <- Repo.get(OAuthDeviceTransaction, id) do
      {:ok, view(row, DateTime.utc_now())}
    else
      nil -> {:error, error(:device_authorization_not_found)}
      {:error, reason} -> {:error, reason}
    end
  rescue
    _ in [DBConnection.ConnectionError, Postgrex.Error] -> {:error, database_error()}
  end

  def cancel(id) do
    with {:ok, id} <- uuid(id) do
      transaction(fn ->
        case locked(id) do
          nil -> Repo.rollback(error(:device_authorization_not_found))
          %{status: "complete"} -> Repo.rollback(error(:device_authorization_unavailable))
          row -> finish(row, "cancelled") |> view(DateTime.utc_now())
        end
      end)
    end
  rescue
    _ in [DBConnection.ConnectionError, Postgrex.Error] -> {:error, database_error()}
  end

  def poll(id, opts \\ []) do
    with {:ok, id} <- uuid(id),
         {:ok, resolved} <- config(),
         {:ok, claim} <- claim(id, resolved, now(opts)) do
      case claim do
        {:pending, safe} -> {:pending, safe}
        %OAuthDeviceTransaction{} = row -> poll_claim(row, resolved, opts)
      end
    else
      {:error, reason} -> {:error, normalize_error(reason)}
    end
  rescue
    _ in [DBConnection.ConnectionError, Postgrex.Error] -> {:error, database_error()}
  end

  defp claim(id, resolved, now) do
    transaction(fn ->
      with :ok <- generation(resolved.setting_id, resolved.setting_lock_version),
           %OAuthDeviceTransaction{} = row <- locked(id),
           :ok <- match_generation(row, resolved),
           :ok <- active_account(row.account_id) do
        cond do
          row.status not in ["pending", "polling"] ->
            {:error, error(:device_authorization_unavailable)}

          DateTime.compare(row.expires_at, now) != :gt ->
            finish(row, "expired")
            {:error, error(:device_authorization_expired)}

          row.status == "polling" and DateTime.compare(row.claim_expires_at, now) != :gt ->
            finish(row, "failed")
            {:error, error(:device_authorization_failed)}

          row.status == "polling" ->
            {:pending, view(row, now)}

          row.status != "pending" ->
            {:error, error(:device_authorization_unavailable)}

          DateTime.compare(row.next_poll_at, now) == :gt ->
            {:pending, view(row, now)}

          true ->
            update_transaction(row,
              status: "polling",
              claim_id: Ecto.UUID.generate(),
              claim_expires_at: DateTime.add(now, @claim_seconds, :second)
            )
        end
      else
        nil -> Repo.rollback(error(:device_authorization_not_found))
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, {:error, reason}} -> {:error, reason}
      result -> result
    end
  end

  defp poll_claim(row, resolved, opts) do
    with :ok <- still_valid(row, resolved, now(opts)),
         {:ok, code} <-
           Crypto.decrypt(row.device_code_ciphertext, context(row.id, row.account_id)) do
      provider_options = provider_opts(opts, row.required_scopes)

      case adapter(opts).poll_device_code(code, resolved.config, provider_options) do
        {:pending, reason} when reason in [:authorization_pending, :slow_down] ->
          release_pending(row, reason, resolved, now(opts))

        {:ok, %Token{} = token} ->
          with :ok <- still_valid(row, resolved, now(opts)) do
            complete(row, token, resolved, opts)
          else
            {:error, reason} ->
              fail_claim(row)
              {:error, normalize_error(reason)}
          end

        {:error, reason} ->
          fail_claim(row)
          {:error, normalize_error(reason)}
      end
    else
      {:error, reason} ->
        fail_claim(row)
        {:error, normalize_error(reason)}
    end
  end

  defp complete(row, token, resolved, opts) do
    consumed = %Consumed{
      provider: "microsoft",
      mailbox_id: row.account_id,
      purpose: String.to_existing_atom(row.purpose),
      required_scopes: row.required_scopes,
      redirect_uri: nil,
      pkce_verifier: nil,
      oauth_provider_setting_id: row.oauth_provider_setting_id,
      oauth_provider_setting_lock_version: row.oauth_provider_setting_lock_version
    }

    guard = fn ->
      with %OAuthDeviceTransaction{} = current <- locked(row.id),
           :ok <- valid_claim(current, row, now(opts)) do
        finish(current, "complete")
        :ok
      else
        nil -> {:error, error(:device_authorization_not_found)}
        {:error, reason} -> {:error, reason}
      end
    end

    case OAuthAuthorizations.complete_token(
           "microsoft",
           token,
           consumed,
           adapter(opts),
           resolved.config,
           Keyword.put(opts, :completion_guard, guard)
         ) do
      {:ok, method} ->
        {:ok, method}

      {:error, reason} ->
        fail_claim(row)
        {:error, normalize_error(reason)}
    end
  end

  defp release_pending(row, reason, resolved, now) do
    transaction(fn ->
      with :ok <- generation(resolved.setting_id, resolved.setting_lock_version),
           %OAuthDeviceTransaction{} = current <- locked(row.id),
           :ok <- valid_claim(current, row, now),
           :ok <- active_account(current.account_id) do
        interval = current.interval + if(reason == :slow_down, do: 5, else: 0)

        update_transaction(current,
          status: "pending",
          claim_id: nil,
          claim_expires_at: nil,
          interval: interval,
          next_poll_at: DateTime.add(now, interval, :second)
        )
        |> view(now)
      else
        nil -> Repo.rollback(error(:device_authorization_not_found))
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, safe} -> {:pending, safe}
      error -> error
    end
  end

  defp still_valid(row, resolved, now) do
    with {:ok, latest} <- config(),
         :ok <- match_generation(row, latest),
         :ok <- match_generation(row, resolved),
         :ok <- active_account(row.account_id),
         %OAuthDeviceTransaction{} = current <- Repo.get(OAuthDeviceTransaction, row.id) do
      valid_claim(current, row, now)
    else
      nil -> {:error, error(:device_authorization_not_found)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp valid_claim(current, row, now) do
    cond do
      current.status != "polling" or current.claim_id != row.claim_id ->
        {:error, error(:device_authorization_unavailable)}

      DateTime.compare(current.expires_at, now) != :gt ->
        {:error, error(:device_authorization_expired)}

      DateTime.compare(current.claim_expires_at, now) != :gt ->
        {:error, error(:device_authorization_failed)}

      true ->
        :ok
    end
  end

  defp fail_claim(row) do
    transaction(fn ->
      case locked(row.id) do
        %OAuthDeviceTransaction{claim_id: id, status: "polling"} = current
        when id == row.claim_id ->
          finish(current, "failed")

        _ ->
          :ok
      end
    end)
  end

  defp required_scopes(account_id, purpose) do
    {:ok, scopes} = OAuthScopes.purpose("microsoft", purpose)

    existing =
      OAuthAuthorization
      |> where([a], a.account_id == ^account_id and a.provider == "microsoft")
      |> select([a], a.granted_scopes)
      |> Repo.one()
      |> List.wrap()
      |> List.flatten()
      |> Enum.filter(&OAuthScopes.approved?("microsoft", &1))

    {:ok, Enum.sort(Enum.uniq(scopes ++ existing))}
  end

  defp config do
    with {:ok, resolved} <- ProviderConfig.fetch("microsoft") do
      if Keyword.get(resolved.config, :auth_flow) == "device_code",
        do: {:ok, resolved},
        else: {:error, error(:device_authorization_not_configured)}
    end
  end

  defp generation(id, version) do
    with :ok <- ProviderSettings.lock_provider_for_transaction("microsoft"),
         do: ProviderSettings.validate_generation_for_transaction("microsoft", id, version)
  end

  defp match_generation(row, resolved) do
    if row.oauth_provider_setting_id == resolved.setting_id and
         row.oauth_provider_setting_lock_version == resolved.setting_lock_version,
       do: :ok,
       else: {:error, error(:provider_configuration_changed)}
  end

  defp active_account(id) do
    case Accounts.get_account(id) do
      %{active: true, purge_requested_at: nil} -> :ok
      _ -> {:error, error(:account_disconnected)}
    end
  end

  defp locked(id),
    do: OAuthDeviceTransaction |> where([t], t.id == ^id) |> lock("FOR UPDATE") |> Repo.one()

  defp update_transaction(row, attrs), do: row |> Ecto.Changeset.change(attrs) |> Repo.update!()

  defp finish(row, status),
    do:
      update_transaction(row,
        status: status,
        device_code_ciphertext: nil,
        claim_id: nil,
        claim_expires_at: nil
      )

  defp context(id, account_id), do: "oauth-device:microsoft:" <> account_id <> ":" <> id
  defp now(opts), do: Keyword.get(opts, :now, DateTime.utc_now())
  defp adapter(opts), do: Keyword.get(opts, :adapter, MicrosoftGraph)

  defp provider_opts(opts, scopes),
    do:
      Keyword.get(opts, :provider_opts, [])
      |> Keyword.put(:required_scopes, Enum.uniq(scopes ++ OAuthScopes.identity("microsoft")))
      |> Keyword.put(:now, now(opts))

  defp purpose(p) when p in [:receive, "receive"], do: {:ok, :receive}
  defp purpose(p) when p in [:send, "send"], do: {:ok, :send}
  defp purpose(_), do: {:error, error(:invalid_oauth_purpose)}

  defp uuid(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, error(:invalid_oauth_request)}
    end
  end

  defp view(row, now) do
    status =
      if row.status in ["pending", "polling"] and DateTime.compare(row.expires_at, now) != :gt,
        do: "expired",
        else: row.status

    %{
      id: row.id,
      account_id: row.account_id,
      purpose: row.purpose,
      user_code: row.user_code,
      verification_uri: row.verification_uri,
      expires_at: row.expires_at,
      interval: row.interval,
      poll_after_seconds: max(1, DateTime.diff(row.next_poll_at, now, :second)),
      status: status
    }
  end

  defp error(reason),
    do: Error.new(:permanent, reason, "Microsoft device authorization could not continue")

  defp normalize_error(%Error{} = error), do: error

  defp normalize_error(%ProviderError{class: class, code: code}),
    do:
      Error.new(
        if(class == :temporary, do: :temporary, else: :permanent),
        code,
        "Microsoft device authorization could not continue"
      )

  defp normalize_error(_), do: error(:device_authorization_failed)

  defp database_error,
    do: Error.new(:temporary, :database_unavailable, "OAuth database is unavailable")

  defp transaction(fun) do
    Repo.transaction(fun)
  rescue
    _ in [DBConnection.ConnectionError, Postgrex.Error] ->
      {:error, database_error()}
  end
end
