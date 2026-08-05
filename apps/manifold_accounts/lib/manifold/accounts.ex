defmodule Manifold.Accounts do
  @moduledoc """
  Account configuration and recipient resolution.
  """

  import Ecto.Query

  alias Manifold.Accounts.{RecipientSnapshot, Route, SenderIdentity}
  alias Manifold.Accounts.RecipientSnapshot.Domain, as: SnapshotDomain
  alias Manifold.Accounts.RecipientSnapshot.Route, as: SnapshotRoute
  alias Manifold.Accounts.Schema.{Alias, AliasTarget, Domain, Mailbox, RouteRevision}
  alias Manifold.Core.{Address, Error, RouteSnapshotDigest}
  alias Manifold.Repo

  @type create_result(schema) :: {:ok, schema} | {:error, Ecto.Changeset.t()}

  @spec list_domains() :: [Domain.t()]
  def list_domains do
    Domain
    |> order_by([d], asc: d.normalized_domain)
    |> Repo.all()
  end

  @spec get_domain_by_name!(String.t()) :: Domain.t()
  def get_domain_by_name!(name) do
    with {:ok, normalized} <- Manifold.Core.Domain.normalize(name) do
      Repo.get_by!(Domain, normalized_domain: normalized)
    else
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec create_domain(map()) :: create_result(Domain.t())
  def create_domain(attrs) do
    %Domain{}
    |> Domain.changeset(attrs)
    |> insert_routing_resource()
  end

  @spec list_mailboxes() :: [Mailbox.t()]
  def list_mailboxes do
    Mailbox
    |> join(:inner, [m], d in Domain, on: d.id == m.domain_id)
    |> order_by([m, d], asc: d.normalized_domain, asc: m.canonical_local_part)
    |> preload([m, d], domain: d)
    |> Repo.all()
  end

  @spec list_active_mailboxes() :: [Mailbox.t()]
  def list_active_mailboxes do
    Mailbox
    |> join(:inner, [m], d in Domain, on: d.id == m.domain_id)
    |> where([m, d], m.active and d.active)
    |> order_by([m, d], asc: d.normalized_domain, asc: m.canonical_local_part)
    |> preload([m, d], domain: d)
    |> Repo.all()
  end

  @spec list_mailboxes(Domain.t()) :: [Mailbox.t()]
  def list_mailboxes(%Domain{id: domain_id}) do
    Mailbox
    |> where([m], m.domain_id == ^domain_id)
    |> order_by([m], asc: m.canonical_local_part)
    |> Repo.all()
  end

  @spec get_mailbox!(Ecto.UUID.t()) :: Mailbox.t()
  def get_mailbox!(id), do: Repo.get!(Mailbox, id)

  @spec get_sender_identity(Ecto.UUID.t()) :: {:ok, SenderIdentity.t()} | {:error, Error.t()}
  def get_sender_identity(mailbox_id) do
    query =
      from(mailbox in Mailbox,
        join: domain in Domain,
        on: domain.id == mailbox.domain_id,
        where: mailbox.id == ^mailbox_id and mailbox.active and domain.active,
        select: {mailbox, domain}
      )

    case Repo.one(query) do
      {%Mailbox{} = mailbox, %Domain{} = domain} ->
        address = mailbox.local_part <> "@" <> domain.normalized_domain

        {:ok,
         %SenderIdentity{
           mailbox_id: mailbox.id,
           domain_id: domain.id,
           display_name: mailbox.display_name,
           address: address,
           canonical_address: String.downcase(address, :ascii)
         }}

      nil ->
        {:error, Error.new(:permanent, :sender_not_active, "sender mailbox is not active")}
    end
  rescue
    DBConnection.ConnectionError ->
      {:error,
       Error.new(:temporary, :database_unavailable, "sender database is temporarily unavailable")}
  end

  @spec mailbox_domain_id(Ecto.UUID.t()) :: {:ok, Ecto.UUID.t()} | {:error, Error.t()}
  def mailbox_domain_id(mailbox_id) do
    case Repo.get(Mailbox, mailbox_id) do
      %Mailbox{domain_id: domain_id} ->
        {:ok, domain_id}

      nil ->
        {:error,
         Error.new(:temporary, :database_unavailable, "mailbox not found during archival")}
    end
  end

  @spec active_mailbox_domain_id(Ecto.UUID.t()) ::
          {:ok, Ecto.UUID.t()} | {:error, Error.t()}
  def active_mailbox_domain_id(mailbox_id) do
    query =
      from(mailbox in Mailbox,
        join: domain in Domain,
        on: domain.id == mailbox.domain_id,
        where: mailbox.id == ^mailbox_id and mailbox.active and domain.active,
        select: domain.id
      )

    case Repo.one(query) do
      domain_id when is_binary(domain_id) ->
        {:ok, domain_id}

      nil ->
        {:error, Error.new(:permanent, :mailbox_not_active, "mailbox destination is not active")}
    end
  rescue
    DBConnection.ConnectionError ->
      {:error,
       Error.new(:temporary, :database_unavailable, "mailbox database is temporarily unavailable")}
  end

  @spec create_mailbox(Domain.t(), map()) :: create_result(Mailbox.t())
  def create_mailbox(%Domain{id: domain_id}, attrs) do
    attrs = Map.put(attrs, :domain_id, domain_id)

    %Mailbox{}
    |> Mailbox.changeset(attrs)
    |> insert_routing_resource()
  end

  @spec ensure_mailbox_for_address(String.t()) ::
          {:ok, Mailbox.t()} | {:error, Error.t() | Ecto.Changeset.t()}
  def ensure_mailbox_for_address(address) when is_binary(address) do
    with {:ok, parsed} <- Address.parse(address) do
      Repo.transaction(fn ->
        domain =
          case Repo.get_by(Domain, normalized_domain: parsed.domain) do
            %Domain{} = domain ->
              domain

            nil ->
              case create_domain(%{name: parsed.domain, active: true}) do
                {:ok, domain} -> domain
                {:error, changeset} -> Repo.rollback(changeset)
              end
          end

        mailbox =
          Mailbox
          |> where(
            [m],
            m.domain_id == ^domain.id and m.canonical_local_part == ^parsed.canonical_local_part
          )
          |> preload(:domain)
          |> Repo.one()

        case mailbox do
          %Mailbox{} = mailbox ->
            mailbox

          nil ->
            case create_mailbox(domain, %{local_part: parsed.local_part, active: true}) do
              {:ok, mailbox} -> Repo.preload(mailbox, :domain)
              {:error, changeset} -> Repo.rollback(changeset)
            end
        end
      end)
      |> case do
        {:ok, mailbox} -> {:ok, mailbox}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @spec list_aliases() :: [Alias.t()]
  def list_aliases do
    Alias
    |> join(:inner, [a], d in Domain, on: d.id == a.domain_id)
    |> order_by([a, d], asc: d.normalized_domain, asc: a.canonical_local_part)
    |> preload([a, d], domain: d)
    |> Repo.all()
  end

  @spec list_aliases(Domain.t()) :: [Alias.t()]
  def list_aliases(%Domain{id: domain_id}) do
    Alias
    |> where([a], a.domain_id == ^domain_id)
    |> order_by([a], asc: a.canonical_local_part)
    |> Repo.all()
  end

  @spec create_alias(Domain.t(), map()) :: create_result(Alias.t())
  def create_alias(%Domain{id: domain_id}, attrs) do
    attrs = Map.put(attrs, :domain_id, domain_id)

    %Alias{}
    |> Alias.changeset(attrs)
    |> insert_routing_resource()
  end

  @spec add_alias_target(Alias.t(), Mailbox.t(), map()) :: create_result(AliasTarget.t())
  def add_alias_target(%Alias{id: alias_id}, %Mailbox{id: mailbox_id}, attrs \\ %{}) do
    attrs =
      attrs
      |> Map.put(:alias_id, alias_id)
      |> Map.put(:mailbox_id, mailbox_id)

    %AliasTarget{}
    |> AliasTarget.changeset(attrs)
    |> insert_routing_resource()
  end

  @doc """
  Returns a deterministic, versioned projection of active recipient routes.
  """
  @spec recipient_snapshot(keyword()) ::
          {:ok, RecipientSnapshot.t()} | {:error, Error.t()}
  def recipient_snapshot(opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    ttl_seconds = Keyword.get(opts, :ttl_seconds, 86_400)

    Repo.transaction(
      fn ->
        revision = Repo.one!(from(r in RouteRevision, select: r.revision))
        domains = snapshot_domains()
        routes = snapshot_routes()

        %RecipientSnapshot{
          schema_version: 1,
          revision: revision,
          generated_at: now,
          expires_at: DateTime.add(now, ttl_seconds, :second),
          digest: snapshot_digest(domains, routes),
          domains: domains,
          routes: routes
        }
      end,
      isolation: :repeatable_read
    )
  rescue
    DBConnection.ConnectionError ->
      {:error,
       Error.new(
         :temporary,
         :database_unavailable,
         "recipient database is temporarily unavailable"
       )}
  end

  @spec resolve_recipient(String.t(), Keyword.t()) :: {:ok, Route.t()} | {:error, Error.t()}
  def resolve_recipient(address, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    with {:ok, parsed} <- Address.parse(address),
         {:ok, route} <- resolve_parsed(parsed, repo) do
      {:ok, route}
    end
  rescue
    DBConnection.ConnectionError ->
      {:error,
       Error.new(
         :temporary,
         :database_unavailable,
         "recipient database is temporarily unavailable"
       )}
  end

  defp resolve_parsed(%Address{} = parsed, repo) do
    case repo.get_by(Domain, normalized_domain: parsed.domain, active: true) do
      %Domain{} = domain ->
        resolve_exact_mailbox(parsed, domain, repo) ||
          resolve_exact_alias(parsed, domain, repo) ||
          resolve_plus(parsed, domain, repo) ||
          unknown(parsed)

      nil ->
        unknown(parsed)
    end
  end

  defp resolve_exact_mailbox(parsed, domain, repo) do
    Mailbox
    |> where([m], m.domain_id == ^domain.id)
    |> where([m], m.canonical_local_part == ^parsed.canonical_local_part)
    |> where([m], m.active)
    |> repo.one()
    |> case do
      %Mailbox{} = mailbox ->
        route(parsed, domain, parsed.canonical_local_part, nil, [mailbox.id])

      nil ->
        nil
    end
  end

  defp resolve_exact_alias(parsed, domain, repo) do
    case active_alias_targets(parsed.canonical_local_part, domain.id, repo) do
      [] -> nil
      mailbox_ids -> route(parsed, domain, parsed.canonical_local_part, nil, mailbox_ids)
    end
  end

  defp resolve_plus(parsed, %Domain{plus_addressing_enabled: true} = domain, repo) do
    case Address.split_plus(parsed.canonical_local_part) do
      {base, plus_tag} when is_binary(plus_tag) ->
        resolve_plus_mailbox(parsed, domain, base, plus_tag, repo) ||
          resolve_plus_alias(parsed, domain, base, plus_tag, repo)

      _ ->
        nil
    end
  end

  defp resolve_plus(_parsed, _domain, _repo), do: nil

  defp resolve_plus_mailbox(parsed, domain, base, plus_tag, repo) do
    Mailbox
    |> where([m], m.domain_id == ^domain.id)
    |> where([m], m.canonical_local_part == ^base)
    |> where([m], m.active and m.plus_addressing_enabled)
    |> repo.one()
    |> case do
      %Mailbox{} = mailbox -> route(parsed, domain, base, plus_tag, [mailbox.id])
      nil -> nil
    end
  end

  defp resolve_plus_alias(parsed, domain, base, plus_tag, repo) do
    case active_alias_targets(base, domain.id, repo, plus: true) do
      [] -> nil
      mailbox_ids -> route(parsed, domain, base, plus_tag, mailbox_ids)
    end
  end

  defp active_alias_targets(canonical_local_part, domain_id, repo, opts \\ []) do
    plus? = Keyword.get(opts, :plus, false)

    AliasTarget
    |> join(:inner, [t], a in Alias, on: a.id == t.alias_id)
    |> join(:inner, [t, a], m in Mailbox, on: m.id == t.mailbox_id)
    |> where([t, a, m], a.domain_id == ^domain_id)
    |> where([t, a, m], a.canonical_local_part == ^canonical_local_part)
    |> where([t, a, m], t.active and a.active and m.active)
    |> maybe_require_plus_enabled(plus?)
    |> order_by([t, a, m], asc: m.id)
    |> select([t, a, m], m.id)
    |> repo.all()
  end

  defp maybe_require_plus_enabled(query, false), do: query

  defp maybe_require_plus_enabled(query, true) do
    where(query, [t, a, m], a.plus_addressing_enabled)
  end

  defp route(parsed, domain, canonical_local_part, plus_tag, mailbox_ids) do
    {:ok,
     %Route{
       original_recipient: parsed.original,
       canonical_recipient: canonical_local_part <> "@" <> domain.normalized_domain,
       plus_tag: plus_tag,
       domain_id: domain.id,
       mailbox_ids: mailbox_ids
     }}
  end

  defp unknown(parsed) do
    {:error,
     Error.new(:permanent, :unknown_recipient, "recipient is not configured", %{
       recipient: parsed.canonical
     })}
  end

  defp insert_routing_resource(changeset) do
    Ecto.Multi.new()
    |> Ecto.Multi.insert(:resource, changeset)
    |> Ecto.Multi.update_all(
      :route_revision,
      RouteRevision,
      inc: [revision: 1],
      set: [updated_at: DateTime.utc_now()]
    )
    |> Repo.transaction()
    |> case do
      {:ok, %{resource: resource}} -> {:ok, resource}
      {:error, :resource, changeset, _changes} -> {:error, changeset}
      {:error, operation, reason, _changes} -> {:error, {operation, reason}}
    end
  end

  defp snapshot_domains do
    Domain
    |> where([domain], domain.active)
    |> order_by([domain], asc: domain.normalized_domain, asc: domain.id)
    |> select(
      [domain],
      {domain.id, domain.normalized_domain, domain.plus_addressing_enabled}
    )
    |> Repo.all()
    |> Enum.map(fn {id, name, plus_addressing_enabled} ->
      %SnapshotDomain{
        id: id,
        name: name,
        plus_addressing_enabled: plus_addressing_enabled
      }
    end)
  end

  defp snapshot_routes do
    mailbox_routes = snapshot_mailbox_routes()
    mailbox_addresses = MapSet.new(mailbox_routes, & &1.canonical_address)

    mailbox_routes ++
      (snapshot_alias_routes()
       |> Enum.reject(&MapSet.member?(mailbox_addresses, &1.canonical_address)))
  end

  defp snapshot_mailbox_routes do
    Mailbox
    |> join(:inner, [mailbox], domain in Domain, on: domain.id == mailbox.domain_id)
    |> where([mailbox, domain], mailbox.active and domain.active)
    |> order_by(
      [mailbox, domain],
      asc: domain.normalized_domain,
      asc: mailbox.canonical_local_part,
      asc: mailbox.id
    )
    |> select(
      [mailbox, domain],
      {
        mailbox.canonical_local_part,
        domain.normalized_domain,
        domain.id,
        mailbox.id,
        domain.plus_addressing_enabled and mailbox.plus_addressing_enabled
      }
    )
    |> Repo.all()
    |> Enum.map(fn {local_part, domain, domain_id, mailbox_id, plus_enabled} ->
      %SnapshotRoute{
        canonical_address: local_part <> "@" <> domain,
        domain_id: domain_id,
        mailbox_ids: [mailbox_id],
        plus_addressing_enabled: plus_enabled
      }
    end)
  end

  defp snapshot_alias_routes do
    AliasTarget
    |> join(:inner, [target], alias_schema in Alias, on: alias_schema.id == target.alias_id)
    |> join(:inner, [target, alias_schema], mailbox in Mailbox,
      on: mailbox.id == target.mailbox_id
    )
    |> join(:inner, [target, alias_schema, mailbox], domain in Domain,
      on: domain.id == alias_schema.domain_id
    )
    |> where(
      [target, alias_schema, mailbox, domain],
      target.active and alias_schema.active and mailbox.active and domain.active
    )
    |> order_by(
      [target, alias_schema, mailbox, domain],
      asc: domain.normalized_domain,
      asc: alias_schema.canonical_local_part,
      asc: mailbox.id
    )
    |> select(
      [target, alias_schema, mailbox, domain],
      {
        alias_schema.canonical_local_part,
        domain.normalized_domain,
        domain.id,
        mailbox.id,
        domain.plus_addressing_enabled and alias_schema.plus_addressing_enabled
      }
    )
    |> Repo.all()
    |> Enum.chunk_by(fn {local_part, domain, domain_id, _mailbox_id, plus_enabled} ->
      {local_part, domain, domain_id, plus_enabled}
    end)
    |> Enum.map(fn rows ->
      [{local_part, domain, domain_id, _mailbox_id, plus_enabled} | _rest] = rows

      %SnapshotRoute{
        canonical_address: local_part <> "@" <> domain,
        domain_id: domain_id,
        mailbox_ids: Enum.map(rows, &elem(&1, 3)),
        plus_addressing_enabled: plus_enabled
      }
    end)
  end

  defp snapshot_digest(domains, routes) do
    {:ok, digest} = RouteSnapshotDigest.compute(1, domains, routes)
    digest
  end
end
