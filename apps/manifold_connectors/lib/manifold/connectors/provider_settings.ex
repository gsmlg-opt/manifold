defmodule Manifold.Connectors.ProviderSettings do
  @moduledoc false

  import Ecto.Changeset
  import Ecto.Query

  alias Manifold.Connectors.{Crypto, OAuthProviderCatalog}

  alias Manifold.Connectors.Schema.{
    OAuthAuthorization,
    OAuthProviderSetting,
    ReceiveMethod,
    SendMethod
  }

  alias Manifold.Core.Error
  alias Manifold.Repo

  defmodule Credentials do
    @moduledoc false

    @derive {Inspect, only: [:client_id, :setting_id, :setting_lock_version]}
    @enforce_keys [:client_id, :client_secret, :setting_id, :setting_lock_version]
    defstruct [:client_id, :client_secret, :setting_id, :setting_lock_version]

    @type t :: %__MODULE__{
            client_id: String.t(),
            client_secret: String.t(),
            setting_id: Ecto.UUID.t(),
            setting_lock_version: pos_integer()
          }
  end

  defmodule Form do
    @moduledoc false

    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:provider, :string)
      field(:client_id, :string)
      field(:client_secret, :string, virtual: true, redact: true)
      field(:lock_version, :integer)
    end

    @type t :: %__MODULE__{
            provider: String.t(),
            client_id: String.t() | nil,
            client_secret: nil,
            lock_version: pos_integer() | nil
          }

    @spec changeset(t(), map()) :: Ecto.Changeset.t()
    def changeset(form, attrs) do
      form
      |> cast(attrs, [:client_id])
      |> validate_required(:client_id)
    end
  end

  @type safe_view :: %{
          provider: String.t(),
          client_id: String.t() | nil,
          client_secret_configured?: boolean(),
          status: :configured | :not_configured | :configuration_error,
          lock_version: pos_integer() | nil
        }

  @spec list() :: {:ok, [safe_view()]} | {:error, Error.t()}
  def list do
    OAuthProviderCatalog.list()
    |> Enum.reduce_while({:ok, []}, fn definition, {:ok, views} ->
      case get(definition.key) do
        {:ok, view} -> {:cont, {:ok, [view | views]}}
        {:error, %Error{} = error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, views} -> {:ok, Enum.reverse(views)}
      {:error, %Error{} = error} -> {:error, error}
    end
  rescue
    _error in [DBConnection.ConnectionError, Postgrex.Error, ArgumentError] ->
      {:error, database_error()}
  end

  @spec get(String.t()) :: {:ok, safe_view()} | {:error, Error.t()}
  def get(provider) do
    with {:ok, _definition} <- OAuthProviderCatalog.fetch(provider) do
      provider
      |> get_setting()
      |> safe_view(provider)
      |> then(&{:ok, &1})
    end
  rescue
    _error in [DBConnection.ConnectionError, Postgrex.Error, ArgumentError] ->
      {:error, database_error()}
  end

  @spec change(String.t(), map()) :: Ecto.Changeset.t() | {:error, Error.t()}
  def change(provider, attrs \\ %{}) do
    with {:ok, _definition} <- OAuthProviderCatalog.fetch(provider) do
      setting = get_setting(provider)
      attrs = normalize_attrs(attrs)

      setting
      |> form_changeset(provider, attrs)
    end
  rescue
    _error in [DBConnection.ConnectionError, Postgrex.Error, ArgumentError] ->
      {:error, database_error()}
  end

  @spec put(String.t(), map(), Keyword.t()) ::
          {:ok, safe_view()} | {:error, Error.t() | Ecto.Changeset.t()}
  def put(provider, attrs, opts \\ []) do
    with {:ok, _definition} <- OAuthProviderCatalog.fetch(provider) do
      attrs = normalize_attrs(attrs)

      Repo.transaction(fn ->
        with :ok <- acquire_provider_lock(provider),
             setting <- lock_setting(provider),
             :ok <- check_expected_lock_version(setting, opts),
             {:ok, result} <- persist_setting(setting, provider, attrs),
             :ok <- maybe_transition_dependencies(result, setting, provider) do
          result
          |> persisted_setting()
          |> safe_view(provider)
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
      |> unwrap_transaction()
    end
  rescue
    DBConnection.ConnectionError -> {:error, database_error()}
    error in Postgrex.Error -> {:error, database_error(error)}
  end

  @spec remove(String.t(), Keyword.t()) ::
          {:ok, safe_view()} | {:error, Error.t() | Ecto.Changeset.t()}
  def remove(provider, opts \\ []) do
    with {:ok, _definition} <- OAuthProviderCatalog.fetch(provider) do
      Repo.transaction(fn ->
        with :ok <- acquire_provider_lock(provider),
             setting <- lock_setting(provider),
             :ok <- check_expected_lock_version(setting, opts),
             {:ok, view} <- delete_setting(setting, provider) do
          view
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
      |> unwrap_transaction()
    end
  rescue
    DBConnection.ConnectionError -> {:error, database_error()}
    error in Postgrex.Error -> {:error, database_error(error)}
  end

  # Holds the provider-scoped advisory lock until the caller's surrounding transaction ends.
  @doc false
  @spec lock_provider_for_transaction(String.t()) :: :ok | {:error, Error.t()}
  def lock_provider_for_transaction(provider) do
    with {:ok, _definition} <- OAuthProviderCatalog.fetch(provider),
         :ok <- require_transaction() do
      acquire_provider_lock(provider)
    end
  rescue
    _error in [DBConnection.ConnectionError, Postgrex.Error, ArgumentError] ->
      {:error, database_error()}
  end

  @doc false
  @spec runtime_credentials(String.t()) :: {:ok, Credentials.t()} | {:error, Error.t()}
  def runtime_credentials(provider) do
    with {:ok, _definition} <- OAuthProviderCatalog.fetch(provider),
         %OAuthProviderSetting{} = setting <- get_setting(provider) do
      case decrypt_secret(setting) do
        {:ok, client_secret} ->
          {:ok,
           %Credentials{
             client_id: setting.client_id,
             client_secret: client_secret,
             setting_id: setting.id,
             setting_lock_version: setting.lock_version
           }}

        {:error, _crypto_error} ->
          {:error, configuration_error()}
      end
    else
      nil ->
        {:error,
         Error.new(
           :permanent,
           :oauth_provider_not_configured,
           "OAuth provider is not configured"
         )}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    DBConnection.ConnectionError -> {:error, database_error()}
  end

  defp persist_setting(nil, provider, attrs) do
    id = Ecto.UUID.generate()
    changeset = form_changeset(nil, provider, attrs)

    if changeset.valid? do
      with secret when is_binary(secret) <- Map.get(attrs, "client_secret"),
           {:ok, ciphertext} <- Crypto.encrypt(secret, secret_context(id)),
           {:ok, setting} <-
             %OAuthProviderSetting{id: id}
             |> OAuthProviderSetting.changeset(%{
               provider: provider,
               client_id: get_field(changeset, :client_id),
               client_secret_ciphertext: ciphertext,
               key_version: 1,
               lock_version: 1
             })
             |> Repo.insert() do
        {:ok, {:changed, setting}}
      else
        {:error, %Ecto.Changeset{} = persistence_changeset} ->
          {:error, public_persistence_changeset(changeset, persistence_changeset)}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, changeset}
    end
  end

  defp persist_setting(%OAuthProviderSetting{} = setting, provider, attrs) do
    changeset = form_changeset(setting, provider, attrs)

    if changeset.valid? do
      client_id = get_field(changeset, :client_id)
      secret = Map.get(attrs, "client_secret")

      if client_id == setting.client_id and blank_secret?(secret) do
        {:ok, {:unchanged, setting}}
      else
        with secret when is_binary(secret) <- secret,
             {:ok, ciphertext} <- Crypto.encrypt(secret, secret_context(setting.id)),
             {:ok, updated} <-
               setting
               |> OAuthProviderSetting.changeset(%{
                 client_id: client_id,
                 client_secret_ciphertext: ciphertext,
                 lock_version: setting.lock_version + 1
               })
               |> Repo.update() do
          {:ok, {:changed, updated}}
        else
          {:error, %Ecto.Changeset{} = persistence_changeset} ->
            {:error, public_persistence_changeset(changeset, persistence_changeset)}

          {:error, reason} ->
            {:error, reason}
        end
      end
    else
      {:error, changeset}
    end
  end

  defp form_changeset(setting, provider, attrs) do
    form = %Form{
      provider: provider,
      client_id: if(setting, do: setting.client_id),
      lock_version: if(setting, do: setting.lock_version)
    }

    changeset =
      Form.changeset(form, %{
        "client_id" => Map.get(attrs, "client_id", form.client_id)
      })

    client_id = get_field(changeset, :client_id)
    secret = Map.get(attrs, "client_secret")
    secret_required? = is_nil(setting) or client_id != setting.client_id

    validate_secret(changeset, secret, secret_required?)
  end

  defp validate_secret(changeset, secret, required?) do
    cond do
      required? and blank_secret?(secret) ->
        add_error(changeset, :client_secret, "can't be blank")

      is_nil(secret) or is_binary(secret) ->
        changeset

      true ->
        add_error(changeset, :client_secret, "is invalid")
    end
  end

  defp delete_setting(nil, provider), do: {:ok, missing_view(provider)}

  defp delete_setting(%OAuthProviderSetting{} = setting, provider) do
    with :ok <- transition_dependencies(provider),
         {:ok, _setting} <- Repo.delete(setting) do
      {:ok, missing_view(provider)}
    end
  end

  defp maybe_transition_dependencies({:unchanged, _setting}, _previous, _provider), do: :ok

  defp maybe_transition_dependencies({:changed, _setting}, _previous, provider),
    do: transition_dependencies(provider)

  defp transition_dependencies(provider) do
    authorizations =
      OAuthAuthorization
      |> where(
        [authorization],
        authorization.provider == ^provider and authorization.status != "disconnected"
      )
      |> order_by([authorization], asc: authorization.id)
      |> lock("FOR UPDATE")
      |> Repo.all()

    authorization_ids = Enum.map(authorizations, & &1.id)

    receive_methods =
      ReceiveMethod
      |> where(
        [method],
        method.oauth_authorization_id in ^authorization_ids and method.kind == ^provider and
          method.status != "disconnected"
      )
      |> order_by([method], asc: method.id)
      |> lock("FOR UPDATE")
      |> Repo.all()

    send_methods =
      SendMethod
      |> where(
        [method],
        method.oauth_authorization_id in ^authorization_ids and method.kind == ^provider and
          method.status != "disconnected"
      )
      |> order_by([method], asc: method.id)
      |> lock("FOR UPDATE")
      |> Repo.all()

    with :ok <- update_authorizations(authorizations),
         :ok <- update_receive_methods(receive_methods),
         :ok <- update_send_methods(send_methods) do
      :ok
    end
  end

  defp update_authorizations(authorizations) do
    update_each(authorizations, fn authorization ->
      OAuthAuthorization.changeset(authorization, %{
        status: "reconnect_required",
        last_error_class: "permanent",
        last_error_code: "oauth_provider_configuration_changed",
        last_error_message: "OAuth provider configuration changed; reconnect authorization",
        disconnected_at: nil
      })
    end)
  end

  defp update_receive_methods(methods) do
    update_each(methods, fn method ->
      ReceiveMethod.changeset(method, %{
        status: "reconnect_required",
        enabled: false,
        sync_enabled: false,
        last_error_class: "permanent",
        last_error_code: "oauth_provider_configuration_changed",
        last_error_message: "OAuth provider configuration changed; reconnect authorization",
        disconnected_at: nil
      })
    end)
  end

  defp update_send_methods(methods) do
    update_each(methods, fn method ->
      SendMethod.changeset(method, %{
        status: "reconnect_required",
        enabled: false,
        last_error_class: "permanent",
        last_error_code: "oauth_provider_configuration_changed",
        last_error_message: "OAuth provider configuration changed; reconnect authorization",
        disconnected_at: nil
      })
    end)
  end

  defp update_each(records, changeset_fun) do
    Enum.reduce_while(records, :ok, fn record, :ok ->
      case record |> changeset_fun.() |> Repo.update() do
        {:ok, _record} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp check_expected_lock_version(setting, opts) do
    case Keyword.fetch(opts, :expected_lock_version) do
      :error ->
        :ok

      {:ok, nil} when is_nil(setting) ->
        :ok

      {:ok, expected} when not is_nil(setting) and expected == setting.lock_version ->
        :ok

      {:ok, _expected} ->
        {:error, stale_error()}
    end
  end

  defp lock_setting(provider) do
    OAuthProviderSetting
    |> where([setting], setting.provider == ^provider)
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  defp acquire_provider_lock(provider) do
    case Repo.query(
           "SELECT pg_advisory_xact_lock(" <>
             "hashtextextended('oauth_provider_setting:' || $1::text, 0))",
           [provider]
         ) do
      {:ok, _result} -> :ok
      {:error, _error} -> {:error, database_error()}
    end
  end

  defp require_transaction do
    if Repo.in_transaction?() do
      :ok
    else
      {:error,
       Error.new(
         :permanent,
         :oauth_provider_lock_requires_transaction,
         "OAuth provider lock requires a database transaction"
       )}
    end
  end

  defp get_setting(provider), do: Repo.get_by(OAuthProviderSetting, provider: provider)

  defp persisted_setting({_outcome, setting}), do: setting

  defp safe_view(nil, provider), do: missing_view(provider)

  defp safe_view(%OAuthProviderSetting{} = setting, _provider) do
    status =
      if match?({:ok, _secret}, decrypt_secret(setting)),
        do: :configured,
        else: :configuration_error

    %{
      provider: setting.provider,
      client_id: setting.client_id,
      client_secret_configured?: true,
      status: status,
      lock_version: setting.lock_version
    }
  end

  defp missing_view(provider) do
    %{
      provider: provider,
      client_id: nil,
      client_secret_configured?: false,
      status: :not_configured,
      lock_version: nil
    }
  end

  defp decrypt_secret(setting) do
    Crypto.decrypt(setting.client_secret_ciphertext, secret_context(setting.id))
  end

  defp secret_context(setting_id),
    do: "oauth_provider_setting:#{setting_id}:client_secret"

  defp normalize_attrs(attrs) when is_map(attrs) do
    client_id = fetch_attr(attrs, "client_id", :client_id)
    client_secret = fetch_attr(attrs, "client_secret", :client_secret)

    %{}
    |> maybe_put("client_id", normalize_client_id(client_id))
    |> maybe_put("client_secret", client_secret)
  end

  defp normalize_attrs(_attrs), do: %{}

  defp fetch_attr(attrs, string_key, atom_key) do
    cond do
      Map.has_key?(attrs, string_key) -> {:present, Map.get(attrs, string_key)}
      Map.has_key?(attrs, atom_key) -> {:present, Map.get(attrs, atom_key)}
      true -> :missing
    end
  end

  defp normalize_client_id({:present, value}) when is_binary(value),
    do: {:present, String.trim(value)}

  defp normalize_client_id(value), do: value

  defp maybe_put(map, _key, :missing), do: map
  defp maybe_put(map, key, {:present, value}), do: Map.put(map, key, value)

  defp blank_secret?(nil), do: true
  defp blank_secret?(secret) when is_binary(secret), do: String.trim(secret) == ""
  defp blank_secret?(_secret), do: false

  defp public_persistence_changeset(form_changeset, persistence_changeset) do
    persistence_changeset.errors
    |> Enum.reduce(form_changeset, fn {field, {message, options}}, changeset ->
      add_error(changeset, field, message, options)
    end)
    |> Map.put(:action, persistence_changeset.action)
  end

  defp unwrap_transaction({:ok, result}), do: {:ok, result}
  defp unwrap_transaction({:error, reason}), do: {:error, reason}

  defp stale_error do
    Error.new(
      :permanent,
      :stale_oauth_provider_setting,
      "OAuth provider setting changed; reload and try again"
    )
  end

  defp configuration_error do
    Error.new(
      :permanent,
      :oauth_provider_configuration_error,
      "OAuth provider configuration is invalid"
    )
  end

  defp database_error(_error \\ nil) do
    Error.new(
      :temporary,
      :database_unavailable,
      "OAuth provider settings are temporarily unavailable"
    )
  end
end
