defmodule Manifold.Connectors.ProviderConfig do
  @moduledoc false

  alias Manifold.Connectors.{OAuthProviderCatalog, ProviderSettings}
  alias Manifold.Core.Error

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
  def fetch("gmail") do
    with {:ok, definition} <- OAuthProviderCatalog.fetch("gmail"),
         {:ok, credentials} <- ProviderSettings.runtime_credentials("gmail") do
      config =
        definition
        |> gmail_runtime_config()
        |> Keyword.put(:client_id, credentials.client_id)
        |> Keyword.put(:client_secret, credentials.client_secret)

      {:ok,
       %Resolved{
         provider: "gmail",
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

  def fetch("microsoft") do
    config =
      :manifold_connectors
      |> Application.get_env(:providers, [])
      |> Keyword.get(:microsoft, [])

    if configured?(config) do
      {:ok, %Resolved{provider: "microsoft", config: config}}
    else
      {:error, provider_not_configured_error()}
    end
  end

  def fetch(_provider) do
    {:error, Error.new(:permanent, :unsupported_provider, "OAuth provider is not supported")}
  end

  defp gmail_runtime_config(definition) do
    application_config =
      :manifold_connectors
      |> Application.get_env(:providers, [])
      |> gmail_application_config()

    configured_endpoints =
      application_config
      |> Keyword.take(Keyword.keys(definition.runtime_config))

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

  defp gmail_application_config(providers) when is_list(providers) do
    case Keyword.get(providers, :gmail, []) do
      config when is_list(config) -> config
      _other -> []
    end
  end

  defp gmail_application_config(_providers), do: []

  defp configured?(config) when is_list(config) do
    Enum.all?([:client_id, :client_secret, :authorization_url], fn key ->
      case Keyword.get(config, key) do
        value when is_binary(value) -> value != ""
        _other -> false
      end
    end)
  end

  defp configured?(_config), do: false

  defp provider_not_configured_error do
    Error.new(:permanent, :provider_not_configured, "provider is not configured")
  end

  defp provider_configuration_error do
    Error.new(:permanent, :provider_configuration_error, "provider configuration is invalid")
  end
end
