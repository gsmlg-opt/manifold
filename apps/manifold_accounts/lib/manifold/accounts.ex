defmodule Manifold.Accounts do
  @moduledoc """
  Account configuration and recipient resolution.
  """

  import Ecto.Query

  alias Manifold.Accounts.Route
  alias Manifold.Accounts.Schema.{Alias, AliasTarget, Domain, Mailbox, Owner}
  alias Manifold.Core.{Address, Error}
  alias Manifold.Repo

  @type create_result(schema) :: {:ok, schema} | {:error, Ecto.Changeset.t()}

  @spec create_owner(map()) :: create_result(Owner.t())
  def create_owner(attrs) do
    %Owner{}
    |> Owner.registration_changeset(attrs)
    |> Repo.insert()
  end

  @spec get_owner_by_email_and_password(String.t(), String.t()) :: Owner.t() | nil
  def get_owner_by_email_and_password(email, password)
      when is_binary(email) and is_binary(password) do
    owner = Repo.get_by(Owner, email: email)

    if owner && Bcrypt.verify_pass(password, owner.hashed_password) do
      owner
    end
  end

  @spec get_owner!(Ecto.UUID.t()) :: Owner.t()
  def get_owner!(id), do: Repo.get!(Owner, id)

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
    |> Repo.insert()
  end

  @spec list_mailboxes() :: [Mailbox.t()]
  def list_mailboxes do
    Mailbox
    |> join(:inner, [m], d in Domain, on: d.id == m.domain_id)
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

  @spec create_mailbox(Domain.t(), map()) :: create_result(Mailbox.t())
  def create_mailbox(%Domain{id: domain_id}, attrs) do
    attrs = Map.put(attrs, :domain_id, domain_id)

    %Mailbox{}
    |> Mailbox.changeset(attrs)
    |> Repo.insert()
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
    |> Repo.insert()
  end

  @spec add_alias_target(Alias.t(), Mailbox.t(), map()) :: create_result(AliasTarget.t())
  def add_alias_target(%Alias{id: alias_id}, %Mailbox{id: mailbox_id}, attrs \\ %{}) do
    attrs =
      attrs
      |> Map.put(:alias_id, alias_id)
      |> Map.put(:mailbox_id, mailbox_id)

    %AliasTarget{}
    |> AliasTarget.changeset(attrs)
    |> Repo.insert()
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
end
