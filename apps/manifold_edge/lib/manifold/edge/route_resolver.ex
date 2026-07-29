defmodule Manifold.Edge.RouteResolver do
  @moduledoc """
  Pure recipient resolution against one already-frozen edge snapshot.
  """

  alias Manifold.Core.{Address, Error}
  alias Manifold.Edge.{Route, RouteSnapshot}
  alias Manifold.Edge.RouteSnapshot.Route, as: SnapshotRoute

  @spec resolve(RouteSnapshot.t() | nil, String.t(), keyword()) ::
          {:ok, Route.t()} | {:error, Error.t()}
  def resolve(snapshot, address, opts \\ [])

  def resolve(nil, _address, _opts) do
    {:error,
     Error.new(
       :temporary,
       :route_snapshot_unavailable,
       "recipient route snapshot is unavailable"
     )}
  end

  def resolve(%RouteSnapshot{} = snapshot, address, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    with :ok <- validate_fresh(snapshot, now),
         {:ok, parsed} <- Address.parse(address),
         {:ok, route, plus_tag} <- find_route(snapshot, parsed) do
      {:ok,
       %Route{
         original_recipient: parsed.original,
         canonical_recipient: route.canonical_address,
         plus_tag: plus_tag,
         domain_id: route.domain_id,
         mailbox_ids: route.mailbox_ids,
         snapshot_revision: snapshot.revision
       }}
    end
  end

  defp validate_fresh(snapshot, now) do
    if DateTime.compare(snapshot.expires_at, now) == :gt do
      :ok
    else
      {:error,
       Error.new(:temporary, :route_snapshot_expired, "recipient route snapshot has expired")}
    end
  end

  defp find_route(snapshot, parsed) do
    case find_exact(snapshot.routes, parsed.canonical) do
      %SnapshotRoute{} = route ->
        {:ok, route, nil}

      nil ->
        find_plus_route(snapshot.routes, parsed)
    end
  end

  defp find_plus_route(routes, parsed) do
    case Address.split_plus(parsed.canonical_local_part) do
      {base, plus_tag} when is_binary(plus_tag) ->
        canonical_base = base <> "@" <> parsed.domain

        case find_exact(routes, canonical_base) do
          %SnapshotRoute{plus_addressing_enabled: true} = route ->
            {:ok, route, plus_tag}

          _route ->
            unknown(parsed)
        end

      _not_plus ->
        unknown(parsed)
    end
  end

  defp find_exact(routes, canonical_address) do
    Enum.find(routes, &(&1.canonical_address == canonical_address))
  end

  defp unknown(parsed) do
    {:error,
     Error.new(:permanent, :unknown_recipient, "recipient is not configured", %{
       recipient: parsed.canonical
     })}
  end
end
