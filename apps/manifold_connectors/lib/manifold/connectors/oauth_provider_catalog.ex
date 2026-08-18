defmodule Manifold.Connectors.OAuthProviderCatalog do
  @moduledoc """
  Trusted OAuth provider definitions available for database-backed settings.
  """

  alias Manifold.Connectors.OAuthProvider.Gmail
  alias Manifold.Core.Error

  @spec list() :: [map()]
  def list, do: [Gmail.definition()]

  @spec fetch(String.t()) :: {:ok, map()} | {:error, Error.t()}
  def fetch("gmail"), do: {:ok, Gmail.definition()}

  def fetch(_provider) do
    {:error, Error.new(:permanent, :unsupported_provider, "OAuth provider is not supported")}
  end
end
