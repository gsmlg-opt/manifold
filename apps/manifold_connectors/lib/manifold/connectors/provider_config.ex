defmodule Manifold.Connectors.ProviderConfig do
  @moduledoc false

  alias Manifold.Connectors.{OAuthProviderCatalog, ProviderSettings}
  alias Manifold.Core.Error

  @providers ~w(gmail microsoft)
  @endpoint_keys [:authorization_url, :token_url, :userinfo_url, :base_url]

  defmodule Resolved do
    @moduledoc false

    @derive {Inspect, only: [:provider, :setting_id, :setting_lock_version]}
    @enforce_keys [:provider, :config]
    defstruct [:provider, :config, :setting_id, :setting_lock_version]

    @type t :: %__MODULE__{
            provider: String.t(),
            config: keyword(),
            setting_id: Ecto.UUID.t() | nil,
            setting_lock_version: pos_integer() | nil
          }
  end

  @spec fetch(String.t()) :: {:ok, Resolved.t()} | {:error, Error.t()}
  def fetch(provider) when provider in @providers do
    with {:ok, definition} <- OAuthProviderCatalog.fetch(provider),
         {:ok, credentials} <- ProviderSettings.runtime_credentials(provider) do
      config =
        definition
        |> provider_runtime_config(provider)
        |> Keyword.put(:client_id, credentials.client_id)
        |> Keyword.put(:client_secret, credentials.client_secret)

      {:ok,
       %Resolved{
         provider: provider,
         config: config,
         setting_id: credentials.setting_id,
         setting_lock_version: credentials.setting_lock_version
       }}
    else
      {:error, %Error{reason: :oauth_provider_not_configured}} ->
        {:error, provider_not_configured_error()}

      {:error, %Error{reason: :oauth_provider_configuration_error}} ->
        {:error, provider_configuration_error()}

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  def fetch(_provider) do
    {:error, Error.new(:permanent, :unsupported_provider, "OAuth provider is not supported")}
  end

  defp provider_runtime_config(definition, provider) do
    application_config = provider_application_config(provider)

    configured_endpoints =
      application_config
      |> Keyword.take(@endpoint_keys)
      |> Keyword.take(Keyword.keys(definition.runtime_config))
      |> Enum.filter(fn {_key, value} -> is_binary(value) and value != "" end)

    safe_req_options =
      application_config
      |> Keyword.get(:req_options, [])
      |> then(fn
        options when is_list(options) -> Keyword.take(options, [:plug])
        _other -> []
      end)

    definition.runtime_config
    |> Keyword.merge(configured_endpoints)
    |> maybe_put_req_options(safe_req_options)
  end

  defp maybe_put_req_options(config, []), do: config

  defp maybe_put_req_options(config, req_options),
    do: Keyword.put(config, :req_options, req_options)

  defp provider_application_config(provider) when provider in @providers do
    providers = Application.get_env(:manifold_connectors, :providers, [])
    provider_key = String.to_existing_atom(provider)

    if is_list(providers) do
      case Keyword.get(providers, provider_key, []) do
        config when is_list(config) -> config
        _other -> []
      end
    else
      []
    end
  end

  defp provider_not_configured_error do
    Error.new(:permanent, :provider_not_configured, "provider is not configured")
  end

  defp provider_configuration_error do
    Error.new(:permanent, :provider_configuration_error, "provider configuration is invalid")
  end
end
