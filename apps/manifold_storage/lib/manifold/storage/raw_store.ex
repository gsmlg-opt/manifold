defmodule Manifold.Storage.RawStore do
  @moduledoc """
  Raw-message object store boundary.
  """

  @type key :: String.t()
  @type stat :: %{size: non_neg_integer(), sha256: String.t() | nil}

  @callback put_from_path(map(), key(), Path.t(), Keyword.t()) :: {:ok, stat()} | {:error, term()}
  @callback open(map(), key(), Keyword.t()) :: {:ok, File.io_device()} | {:error, term()}
  @callback stat(map(), key(), Keyword.t()) :: {:ok, stat()} | {:error, term()}
  @callback delete(map(), key(), Keyword.t()) :: :ok | {:error, term()}

  @spec put_from_path(key(), Path.t(), Keyword.t()) :: {:ok, stat()} | {:error, term()}
  def put_from_path(key, path, opts \\ []) do
    adapter().put_from_path(config(), key, path, opts)
  end

  @spec open(key(), Keyword.t()) :: {:ok, File.io_device()} | {:error, term()}
  def open(key, opts \\ []) do
    adapter().open(config(), key, opts)
  end

  @spec stat(key(), Keyword.t()) :: {:ok, stat()} | {:error, term()}
  def stat(key, opts \\ []) do
    adapter().stat(config(), key, opts)
  end

  @spec delete(key(), Keyword.t()) :: :ok | {:error, term()}
  def delete(key, opts \\ []) do
    adapter().delete(config(), key, opts)
  end

  @spec build_key(Ecto.UUID.t() | String.t(), DateTime.t(), Ecto.UUID.t() | String.t()) :: key()
  def build_key(domain_id, %DateTime{} = received_at, inbound_delivery_id) do
    year = received_at.year |> Integer.to_string() |> String.pad_leading(4, "0")
    month = received_at.month |> Integer.to_string() |> String.pad_leading(2, "0")

    Path.join([
      "raw",
      to_string(domain_id),
      year,
      month,
      to_string(inbound_delivery_id) <> ".eml"
    ])
  end

  defp adapter, do: Application.fetch_env!(:manifold_storage, :raw_store_backend)

  defp config do
    %{root: Application.fetch_env!(:manifold_storage, :raw_store_dir)}
  end
end
