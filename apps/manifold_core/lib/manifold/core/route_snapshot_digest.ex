defmodule Manifold.Core.RouteSnapshotDigest do
  @moduledoc """
  Canonical digest for versioned recipient route snapshots.
  """

  @spec compute(pos_integer(), [map() | struct()], [map() | struct()]) ::
          {:ok, String.t()} | {:error, :invalid_snapshot}
  def compute(schema_version, domains, routes)
      when is_integer(schema_version) and schema_version > 0 and is_list(domains) and
             is_list(routes) do
    with {:ok, canonical_domains} <- canonical_domains(domains),
         {:ok, canonical_routes} <- canonical_routes(routes) do
      canonical =
        Jason.OrderedObject.new(
          schema_version: schema_version,
          domains: canonical_domains,
          routes: canonical_routes
        )
        |> Jason.encode!()

      {:ok,
       canonical
       |> then(&:crypto.hash(:sha256, &1))
       |> Base.encode16(case: :lower)}
    end
  end

  def compute(_schema_version, _domains, _routes), do: {:error, :invalid_snapshot}

  @spec verify(pos_integer(), [map() | struct()], [map() | struct()], String.t()) ::
          :ok | {:error, :invalid_snapshot}
  def verify(schema_version, domains, routes, expected_digest) when is_binary(expected_digest) do
    with {:ok, actual_digest} <- compute(schema_version, domains, routes),
         true <- secure_compare(actual_digest, expected_digest) do
      :ok
    else
      _invalid -> {:error, :invalid_snapshot}
    end
  end

  def verify(_schema_version, _domains, _routes, _expected_digest),
    do: {:error, :invalid_snapshot}

  defp canonical_domains(domains) do
    map_all(domains, fn domain ->
      with {:ok, id} <- fetch_binary(domain, :id),
           {:ok, name} <- fetch_binary(domain, :name),
           {:ok, plus_enabled} <- fetch_boolean(domain, :plus_addressing_enabled) do
        {:ok,
         Jason.OrderedObject.new(
           id: id,
           name: name,
           plus_addressing_enabled: plus_enabled
         )}
      end
    end)
  end

  defp canonical_routes(routes) do
    map_all(routes, fn route ->
      with {:ok, canonical_address} <- fetch_binary(route, :canonical_address),
           {:ok, domain_id} <- fetch_binary(route, :domain_id),
           {:ok, mailbox_ids} <- fetch_binary_list(route, :mailbox_ids),
           {:ok, plus_enabled} <- fetch_boolean(route, :plus_addressing_enabled) do
        {:ok,
         Jason.OrderedObject.new(
           canonical_address: canonical_address,
           domain_id: domain_id,
           mailbox_ids: mailbox_ids,
           plus_addressing_enabled: plus_enabled
         )}
      end
    end)
  end

  defp map_all(values, mapper) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case mapper.(value) do
        {:ok, canonical} -> {:cont, {:ok, [canonical | acc]}}
        {:error, :invalid_snapshot} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      {:error, :invalid_snapshot} = error -> error
    end
  end

  defp fetch_binary(value, field) do
    case fetch_value(value, field) do
      binary when is_binary(binary) and binary != "" -> {:ok, binary}
      _invalid -> {:error, :invalid_snapshot}
    end
  end

  defp fetch_boolean(value, field) do
    case fetch_value(value, field) do
      boolean when is_boolean(boolean) -> {:ok, boolean}
      _invalid -> {:error, :invalid_snapshot}
    end
  end

  defp fetch_binary_list(value, field) do
    case fetch_value(value, field) do
      values when is_list(values) and values != [] ->
        if Enum.all?(values, &(is_binary(&1) and &1 != "")) do
          {:ok, values}
        else
          {:error, :invalid_snapshot}
        end

      _invalid ->
        {:error, :invalid_snapshot}
    end
  end

  defp fetch_value(%_{} = value, field), do: value |> Map.from_struct() |> Map.get(field)

  defp fetch_value(value, field) when is_map(value) do
    Map.get(value, field, Map.get(value, Atom.to_string(field)))
  end

  defp fetch_value(_value, _field), do: nil

  defp secure_compare(left, right) when byte_size(left) == byte_size(right),
    do: :crypto.hash_equals(left, right)

  defp secure_compare(_left, _right), do: false
end
