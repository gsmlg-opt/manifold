defmodule Manifold.Accounts do
  @moduledoc """
  Local account identity, domain derivation, and recipient resolution.
  """

  import Ecto.Query

  alias Manifold.Accounts.{RecipientSnapshot, Route, SenderIdentity}
  alias Manifold.Accounts.RecipientSnapshot.Domain, as: SnapshotDomain
  alias Manifold.Accounts.RecipientSnapshot.Route, as: SnapshotRoute
  alias Manifold.Accounts.Schema.{Account, Domain, RouteRevision}
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

  @spec list_accounts() :: [Account.t()]
  def list_accounts do
    Account
    |> join(:inner, [a], d in Domain, on: d.id == a.domain_id)
    |> order_by([a, d], asc: d.normalized_domain, asc: a.canonical_local_part)
    |> preload([a, d], domain: d)
    |> Repo.all()
  end

  @spec list_active_accounts() :: [Account.t()]
  def list_active_accounts do
    Account
    |> join(:inner, [a], d in Domain, on: d.id == a.domain_id)
    |> where([a, d], a.active and is_nil(a.purge_requested_at) and d.active)
    |> order_by([a, d], asc: d.normalized_domain, asc: a.canonical_local_part)
    |> preload([a, d], domain: d)
    |> Repo.all()
  end

  @spec list_accounts(Domain.t()) :: [Account.t()]
  def list_accounts(%Domain{id: domain_id}) do
    Account
    |> where([a], a.domain_id == ^domain_id)
    |> order_by([a], asc: a.canonical_local_part)
    |> Repo.all()
  end

  @spec get_account!(Ecto.UUID.t()) :: Account.t()
  def get_account!(id), do: Repo.get!(Account, id) |> Repo.preload(:domain)

  @spec get_account(Ecto.UUID.t()) :: Account.t() | nil
  def get_account(id) do
    case Repo.get(Account, id) do
      nil -> nil
      account -> Repo.preload(account, :domain)
    end
  end

  @spec disable_account(Ecto.UUID.t()) ::
          {:ok, Account.t()} | {:error, Error.t() | term()}
  def disable_account(account_id) do
    Repo.transaction(fn ->
      case disable_account(Repo, account_id) do
        {:ok, account} -> account
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc false
  @spec disable_account(module(), Ecto.UUID.t()) ::
          {:ok, Account.t()} | {:error, Error.t() | Ecto.Changeset.t()}
  def disable_account(repo, account_id) do
    with {:ok, account} <- account_for_update(repo, account_id) do
      transition_lifecycle(repo, account, %{active: false})
    end
  end

  @doc false
  @spec active_account_for_update(module(), Ecto.UUID.t()) ::
          {:ok, Account.t()} | {:error, Error.t()}
  def active_account_for_update(repo, account_id) do
    query =
      Account
      |> joined_domain_query(account_id)
      |> where([account, _domain], account.active and is_nil(account.purge_requested_at))
      |> lock("FOR UPDATE")

    case repo.one(query) do
      %Account{} = account -> {:ok, account}
      nil -> {:error, mailbox_not_active_error()}
    end
  end

  @doc false
  @spec begin_purge(module(), Ecto.UUID.t(), String.t(), DateTime.t()) ::
          {:ok, Account.t()}
          | {:error, :confirmation_mismatch | Error.t() | Ecto.Changeset.t()}
  def begin_purge(repo, account_id, confirmation, %DateTime{} = now) do
    with {:ok, account} <- account_for_update(repo, account_id),
         :ok <- confirm_account_address(account, confirmation) do
      attrs =
        if is_nil(account.purge_requested_at) do
          %{active: false, purge_requested_at: now}
        else
          %{active: false}
        end

      transition_lifecycle(repo, account, attrs)
    end
  end

  @doc false
  @spec delete_purging_account(module(), Ecto.UUID.t()) ::
          {:ok, Account.t()} | {:error, Error.t() | Ecto.Changeset.t()}
  def delete_purging_account(repo, account_id) do
    with {:ok, account} <- account_for_update(repo, account_id),
         :ok <- ensure_purging(account) do
      repo.delete(account)
    end
  end

  @spec account_address(Account.t()) :: String.t()
  def account_address(%Account{} = account) do
    domain = account.domain || Repo.get!(Domain, account.domain_id)
    account.local_part <> "@" <> domain.normalized_domain
  end

  @spec get_sender_identity(Ecto.UUID.t()) :: {:ok, SenderIdentity.t()} | {:error, Error.t()}
  def get_sender_identity(account_id) do
    query =
      from(account in Account,
        join: domain in Domain,
        on: domain.id == account.domain_id,
        where:
          account.id == ^account_id and account.active and
            is_nil(account.purge_requested_at) and domain.active,
        select: {account, domain}
      )

    case Repo.one(query) do
      {%Account{} = account, %Domain{} = domain} ->
        address = account.local_part <> "@" <> domain.normalized_domain

        {:ok,
         %SenderIdentity{
           mailbox_id: account.id,
           domain_id: domain.id,
           display_name: account.name,
           address: address,
           canonical_address: String.downcase(address, :ascii)
         }}

      nil ->
        {:error, Error.new(:permanent, :sender_not_active, "sender account is not active")}
    end
  rescue
    DBConnection.ConnectionError ->
      {:error,
       Error.new(:temporary, :database_unavailable, "sender database is temporarily unavailable")}
  end

  @spec account_domain_id(Ecto.UUID.t()) :: {:ok, Ecto.UUID.t()} | {:error, Error.t()}
  def account_domain_id(account_id) do
    case Repo.get(Account, account_id) do
      %Account{domain_id: domain_id} ->
        {:ok, domain_id}

      nil ->
        {:error,
         Error.new(:temporary, :database_unavailable, "account not found during archival")}
    end
  end

  @spec active_account_domain_id(Ecto.UUID.t()) ::
          {:ok, Ecto.UUID.t()} | {:error, Error.t()}
  def active_account_domain_id(account_id) do
    query =
      from(account in Account,
        join: domain in Domain,
        on: domain.id == account.domain_id,
        where:
          account.id == ^account_id and account.active and
            is_nil(account.purge_requested_at) and domain.active,
        select: domain.id
      )

    case Repo.one(query) do
      domain_id when is_binary(domain_id) ->
        {:ok, domain_id}

      nil ->
        {:error, Error.new(:permanent, :mailbox_not_active, "account destination is not active")}
    end
  rescue
    DBConnection.ConnectionError ->
      {:error,
       Error.new(:temporary, :database_unavailable, "account database is temporarily unavailable")}
  end

  @doc """
  Creates an account from a display name and email address.

  The domain portion of the address is derived automatically (created if missing).
  """
  @spec create_account(map()) :: create_result(Account.t())
  def create_account(attrs) when is_map(attrs) do
    attrs = stringify_keys(attrs)
    address = Map.get(attrs, "address") || Map.get(attrs, :address)
    name = Map.get(attrs, "name") || Map.get(attrs, :name)

    with {:ok, parsed} <- parse_required_address(address) do
      Repo.transaction(fn ->
        domain = ensure_domain!(parsed.domain)

        case do_create_account(domain, %{
               local_part: parsed.local_part,
               name: name,
               active: Map.get(attrs, "active", Map.get(attrs, :active, true)),
               plus_addressing_enabled:
                 Map.get(
                   attrs,
                   "plus_addressing_enabled",
                   Map.get(attrs, :plus_addressing_enabled, true)
                 )
             }) do
          {:ok, account} -> Repo.preload(account, :domain)
          {:error, changeset} -> Repo.rollback(changeset)
        end
      end)
      |> case do
        {:ok, account} -> {:ok, account}
        {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @spec create_account(Domain.t(), map()) :: create_result(Account.t())
  def create_account(%Domain{} = domain, attrs) when is_map(attrs) do
    do_create_account(domain, attrs)
  end

  @doc """
  Updates an account display name and email address.

  The domain portion of the address is derived automatically (created if missing).
  Changing the address advances the recipient route revision.
  """
  @spec update_account(Account.t(), map()) :: create_result(Account.t())
  def update_account(%Account{} = account, attrs) when is_map(attrs) do
    attrs = stringify_keys(attrs)
    address = Map.get(attrs, "address") || Map.get(attrs, :address)
    name = Map.get(attrs, "name") || Map.get(attrs, :name)

    with {:ok, parsed} <- parse_required_address(address) do
      Repo.transaction(fn ->
        domain = ensure_domain!(parsed.domain)

        case do_update_account(account, %{
               domain_id: domain.id,
               local_part: parsed.local_part,
               name: name
             }) do
          {:ok, updated} -> Repo.preload(updated, :domain, force: true)
          {:error, changeset} -> Repo.rollback(changeset)
        end
      end)
      |> case do
        {:ok, account} -> {:ok, account}
        {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @spec ensure_account_for_address(String.t()) ::
          {:ok, Account.t()} | {:error, Error.t() | Ecto.Changeset.t()}
  def ensure_account_for_address(address) when is_binary(address) do
    with {:ok, parsed} <- Address.parse(address) do
      Repo.transaction(fn ->
        domain = ensure_domain!(parsed.domain)

        account =
          Account
          |> where(
            [a],
            a.domain_id == ^domain.id and a.canonical_local_part == ^parsed.canonical_local_part
          )
          |> preload(:domain)
          |> Repo.one()

        case account do
          %Account{} = account ->
            account

          nil ->
            case do_create_account(domain, %{local_part: parsed.local_part, active: true}) do
              {:ok, account} -> Repo.preload(account, :domain)
              {:error, changeset} -> Repo.rollback(changeset)
            end
        end
      end)
      |> case do
        {:ok, account} -> {:ok, account}
        {:error, reason} -> {:error, reason}
      end
    end
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

  defp do_create_account(%Domain{id: domain_id}, attrs) do
    attrs = Map.put(attrs, :domain_id, domain_id)

    %Account{}
    |> Account.changeset(attrs)
    |> insert_routing_resource()
  end

  defp do_update_account(%Account{} = account, attrs) do
    changeset = Account.changeset(account, attrs)

    if routing_fields_changed?(changeset) do
      update_routing_resource(changeset)
    else
      Repo.update(changeset)
    end
  end

  defp routing_fields_changed?(%Ecto.Changeset{} = changeset) do
    Ecto.Changeset.changed?(changeset, :domain_id) or
      Ecto.Changeset.changed?(changeset, :local_part) or
      Ecto.Changeset.changed?(changeset, :canonical_local_part)
  end

  defp ensure_domain!(normalized_or_name) do
    case Repo.get_by(Domain, normalized_domain: normalized_or_name) do
      %Domain{} = domain ->
        domain

      nil ->
        case create_domain(%{name: normalized_or_name, active: true}) do
          {:ok, domain} -> domain
          {:error, changeset} -> Repo.rollback(changeset)
        end
    end
  end

  defp parse_required_address(address) when is_binary(address) and address != "" do
    Address.parse(address)
  end

  defp parse_required_address(_) do
    {:error,
     %Account{}
     |> Account.changeset(%{})
     |> Ecto.Changeset.add_error(:address, "can't be blank")}
  end

  defp stringify_keys(attrs) do
    Map.new(attrs, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end

  defp account_for_update(repo, account_id) do
    query =
      Account
      |> joined_domain_query(account_id)
      |> lock("FOR UPDATE")

    case repo.one(query) do
      %Account{} = account -> {:ok, account}
      nil -> {:error, account_not_found_error()}
    end
  end

  defp joined_domain_query(query, account_id) do
    query
    |> join(:inner, [account], domain in Domain, on: domain.id == account.domain_id)
    |> where([account, _domain], account.id == ^account_id)
    |> preload([_account, domain], domain: domain)
  end

  defp confirm_account_address(%Account{} = account, confirmation) do
    expected = account.local_part <> "@" <> account.domain.normalized_domain

    if String.trim(confirmation) == expected do
      :ok
    else
      {:error, :confirmation_mismatch}
    end
  end

  defp ensure_purging(%Account{purge_requested_at: nil}) do
    {:error,
     Error.new(:permanent, :account_not_purging, "account deletion has not been requested")}
  end

  defp ensure_purging(%Account{}), do: :ok

  defp transition_lifecycle(repo, %Account{} = account, attrs) do
    with {:ok, updated} <- account |> lifecycle_changeset(attrs) |> repo.update(),
         :ok <- maybe_advance_route_revision(repo, account.active and not updated.active) do
      {:ok, updated}
    end
  end

  defp lifecycle_changeset(%Account{} = account, attrs) do
    Ecto.Changeset.cast(account, attrs, [:active, :purge_requested_at])
  end

  defp maybe_advance_route_revision(repo, true) do
    {:ok, _updated_count} = advance_route_revision(repo)
    :ok
  end

  defp maybe_advance_route_revision(_repo, false), do: :ok

  defp advance_route_revision(repo) do
    {updated_count, nil} =
      repo.update_all(
        RouteRevision,
        inc: [revision: 1],
        set: [updated_at: DateTime.utc_now()]
      )

    {:ok, updated_count}
  end

  defp account_not_found_error do
    Error.new(:permanent, :account_not_found, "account not found")
  end

  defp mailbox_not_active_error do
    Error.new(:permanent, :mailbox_not_active, "account destination is not active")
  end

  defp resolve_parsed(%Address{} = parsed, repo) do
    case repo.get_by(Domain, normalized_domain: parsed.domain, active: true) do
      %Domain{} = domain ->
        resolve_exact_account(parsed, domain, repo) ||
          resolve_plus(parsed, domain, repo) ||
          unknown(parsed)

      nil ->
        unknown(parsed)
    end
  end

  defp resolve_exact_account(parsed, domain, repo) do
    Account
    |> where([a], a.domain_id == ^domain.id)
    |> where([a], a.canonical_local_part == ^parsed.canonical_local_part)
    |> where([a], a.active and is_nil(a.purge_requested_at))
    |> repo.one()
    |> case do
      %Account{} = account ->
        route(parsed, domain, parsed.canonical_local_part, nil, [account.id])

      nil ->
        nil
    end
  end

  defp resolve_plus(parsed, %Domain{plus_addressing_enabled: true} = domain, repo) do
    case Address.split_plus(parsed.canonical_local_part) do
      {base, plus_tag} when is_binary(plus_tag) ->
        resolve_plus_account(parsed, domain, base, plus_tag, repo)

      _ ->
        nil
    end
  end

  defp resolve_plus(_parsed, _domain, _repo), do: nil

  defp resolve_plus_account(parsed, domain, base, plus_tag, repo) do
    Account
    |> where([a], a.domain_id == ^domain.id)
    |> where([a], a.canonical_local_part == ^base)
    |> where([a], a.active and is_nil(a.purge_requested_at) and a.plus_addressing_enabled)
    |> repo.one()
    |> case do
      %Account{} = account -> route(parsed, domain, base, plus_tag, [account.id])
      nil -> nil
    end
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
    persist_routing_resource(changeset, :insert)
  end

  defp update_routing_resource(changeset) do
    persist_routing_resource(changeset, :update)
  end

  defp persist_routing_resource(changeset, operation) when operation in [:insert, :update] do
    multi =
      Ecto.Multi.new()
      |> then(fn multi ->
        case operation do
          :insert -> Ecto.Multi.insert(multi, :resource, changeset)
          :update -> Ecto.Multi.update(multi, :resource, changeset)
        end
      end)
      |> Ecto.Multi.run(:route_revision, fn repo, _changes ->
        advance_route_revision(repo)
      end)

    multi
    |> Repo.transaction()
    |> case do
      {:ok, %{resource: resource}} -> {:ok, resource}
      {:error, :resource, changeset, _changes} -> {:error, changeset}
      {:error, failed_operation, reason, _changes} -> {:error, {failed_operation, reason}}
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
    Account
    |> join(:inner, [account], domain in Domain, on: domain.id == account.domain_id)
    |> where(
      [account, domain],
      account.active and is_nil(account.purge_requested_at) and domain.active
    )
    |> order_by(
      [account, domain],
      asc: domain.normalized_domain,
      asc: account.canonical_local_part,
      asc: account.id
    )
    |> select(
      [account, domain],
      {
        account.canonical_local_part,
        domain.normalized_domain,
        domain.id,
        account.id,
        domain.plus_addressing_enabled and account.plus_addressing_enabled
      }
    )
    |> Repo.all()
    |> Enum.map(fn {local_part, domain, domain_id, account_id, plus_enabled} ->
      %SnapshotRoute{
        canonical_address: local_part <> "@" <> domain,
        domain_id: domain_id,
        mailbox_ids: [account_id],
        plus_addressing_enabled: plus_enabled
      }
    end)
  end

  defp snapshot_digest(domains, routes) do
    {:ok, digest} = RouteSnapshotDigest.compute(1, domains, routes)
    digest
  end
end
