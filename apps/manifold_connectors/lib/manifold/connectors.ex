defmodule Manifold.Connectors do
  @moduledoc """
  External mailbox account and synchronization context.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias Manifold.Accounts
  alias Manifold.Connectors.ActivityLog
  alias Manifold.Connectors.Crypto
  alias Manifold.Connectors.IMAP.Client
  alias Manifold.Connectors.Jobs.SyncAccount
  alias Manifold.Connectors.OAuth.Consumed
  alias Manifold.Connectors.Provider.Error, as: ProviderError
  alias Manifold.Connectors.Provider.IMAP, as: ProviderIMAP
  alias Manifold.Connectors.Provider.{Identity, Token}
  alias Manifold.Connectors.Sync

  alias Manifold.Connectors.Schema.{
    ConnectorEvent,
    Credential,
    ReceiveMethod,
    ImapSettings,
    RemoteMessage,
    SyncCursor
  }

  alias Manifold.Connectors.View
  alias Manifold.Core.{Address, Error}
  alias Manifold.Mail
  alias Manifold.Repo

  @required_scopes %{
    "gmail" => MapSet.new(["https://www.googleapis.com/auth/gmail.readonly"]),
    "microsoft" => MapSet.new(["Mail.Read", "offline_access"])
  }

  @spec complete_authorization(String.t(), String.t(), Consumed.t(), Keyword.t()) ::
          {:ok, ReceiveMethod.t()} | {:error, Error.t() | Ecto.Changeset.t()}
  def complete_authorization(provider, code, %Consumed{} = consumed, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    with :ok <- validate_consumed(provider, consumed),
         {:ok, adapter, config} <- adapter_config(provider),
         {:ok, %Token{} = token} <-
           adapter.exchange_code(
             code,
             consumed.pkce_verifier,
             consumed.redirect_uri,
             config,
             provider_opts(opts)
           ),
         :ok <- validate_granted_scopes(provider, token.scopes),
         {:ok, %Identity{} = identity} <-
           adapter.identity(token.access_token, config, provider_opts(opts)),
         {:ok, cursors} <-
           adapter.initial_cursors(token.access_token, config, provider_opts(opts)),
         :ok <- validate_cursors(cursors) do
      persist_authorization(provider, consumed, token, identity, cursors, now, opts)
    else
      {:error, %ProviderError{} = error} -> {:error, provider_error(error)}
      {:error, %Error{} = error} -> {:error, error}
    end
  rescue
    DBConnection.ConnectionError ->
      {:error, database_error(:unavailable)}
  end

  @spec list_receive_methods() :: [View.ReceiveMethod.t()]
  def list_receive_methods do
    ReceiveMethod
    |> order_by([account], asc: account.kind, asc: account.email_address, asc: account.id)
    |> Repo.all()
    |> Enum.map(&account_view/1)
  end

  @spec list_receive_methods_for_account(Ecto.UUID.t()) :: [View.ReceiveMethod.t()]
  def list_receive_methods_for_account(account_id) do
    ReceiveMethod
    |> where([m], m.account_id == ^account_id)
    |> order_by([m], desc: m.enabled, asc: m.kind, asc: m.id)
    |> Repo.all()
    |> Enum.map(&account_view/1)
  end

  @doc false
  def list_accounts, do: list_receive_methods()

  @spec enable_receive_method(Ecto.UUID.t()) ::
          {:ok, ReceiveMethod.t()} | {:error, Error.t() | Ecto.Changeset.t()}
  def enable_receive_method(receive_method_id) do
    Repo.transaction(fn ->
      method =
        ReceiveMethod
        |> where([m], m.id == ^receive_method_id)
        |> lock("FOR UPDATE")
        |> Repo.one()

      case method do
        nil ->
          Repo.rollback(Error.new(:permanent, :account_not_found, "receive method not found"))

        %ReceiveMethod{status: "disconnected"} ->
          Repo.rollback(
            Error.new(:permanent, :account_disconnected, "receive method is disconnected")
          )

        %ReceiveMethod{status: "not_implemented"} ->
          Repo.rollback(
            Error.new(:permanent, :not_implemented, "receive method is not implemented yet")
          )

        %ReceiveMethod{} = method ->
          disable_other_methods(Repo, method.account_id, except_id: method.id)

          case ReceiveMethod.changeset(method, %{enabled: true, sync_enabled: true})
               |> Repo.update() do
            {:ok, updated} -> updated
            {:error, changeset} -> Repo.rollback(changeset)
          end
      end
    end)
  rescue
    DBConnection.ConnectionError -> {:error, database_error(:unavailable)}
  end

  @spec create_placeholder_receive_method(Ecto.UUID.t(), String.t(), map()) ::
          {:ok, ReceiveMethod.t()} | {:error, Error.t() | Ecto.Changeset.t()}
  def create_placeholder_receive_method(account_id, kind, attrs \\ %{})
      when kind in ["pop3", "eas", "ews"] do
    email =
      Map.get(attrs, :email_address) || Map.get(attrs, "email_address") ||
        case Accounts.get_account(account_id) do
          nil -> nil
          account -> Accounts.account_address(account)
        end

    if is_nil(email) do
      {:error, Error.new(:permanent, :account_not_found, "account not found")}
    else
      ReceiveMethod.changeset(%ReceiveMethod{}, %{
        account_id: account_id,
        kind: kind,
        provider_account_id: "#{kind}:#{email}:#{Ecto.UUID.generate()}",
        email_address: email,
        status: "not_implemented",
        enabled: false,
        sync_enabled: false,
        granted_scopes: []
      })
      |> Repo.insert()
    end
  end

  @spec configured_providers() :: [String.t()]
  def configured_providers do
    providers = Application.get_env(:manifold_connectors, :providers, [])

    ["gmail", "microsoft"]
    |> Enum.filter(fn provider ->
      config = Keyword.get(providers, String.to_existing_atom(provider), [])

      Enum.all?([:client_id, :client_secret, :authorization_url], fn key ->
        value = Keyword.get(config, key)
        is_binary(value) and value != ""
      end)
    end)
  end

  @spec test_imap_connection(map()) :: :ok | {:error, Error.t() | ProviderError.t()}
  def test_imap_connection(attrs) when is_map(attrs) do
    attrs = normalize_imap_attrs(attrs)

    with {:ok, settings} <- imap_settings_from_attrs(attrs) do
      transport = imap_transport()

      case transport.connect(settings) do
        {:ok, conn} ->
          mailbox_path = Map.get(settings, :mailbox_path, "INBOX")

          result =
            case transport.select(conn, mailbox_path) do
              {:ok, _meta} -> :ok
              {:error, %ProviderError{} = error} -> {:error, error}
            end

          transport.logout(conn)
          result

        {:error, %ProviderError{} = error} ->
          {:error, error}
      end
    end
  rescue
    e in [ArgumentError, ErlangError, FunctionClauseError] ->
      {:error,
       %ProviderError{
         class: :temporary,
         code: :connect_failed,
         message: "IMAP connect failed: #{Exception.message(e)}"
       }}
  end

  @spec create_imap_account(map()) ::
          {:ok, ReceiveMethod.t()}
          | {:error, Error.t() | Ecto.Changeset.t() | ProviderError.t()}
  def create_imap_account(attrs) when is_map(attrs) do
    attrs = normalize_imap_attrs(attrs)
    now = DateTime.utc_now()
    skip_test? = truthy?(attr(attrs, :skip_test))
    account_id = attr(attrs, :account_id)

    with {:ok, parsed} <- Address.parse(attr(attrs, :email_address) || ""),
         provider_account_id <- "imap:" <> parsed.canonical,
         :ok <- reject_duplicate_imap(parsed.canonical, provider_account_id),
         :ok <- maybe_test_imap(attrs, skip_test?),
         {:ok, mailbox} <- resolve_imap_account(account_id, parsed.canonical),
         {:ok, cursors} <-
           ProviderIMAP.initial_cursors(attr(attrs, :password), imap_provider_config(attrs), []) do
      persist_imap_account(attrs, parsed, provider_account_id, mailbox, cursors, now)
    else
      {:error, %ProviderError{} = error} -> {:error, error}
      {:error, %Error{} = error} -> {:error, error}
      {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e in [DBConnection.ConnectionError, Postgrex.Error] ->
      {:error, database_error(e)}

    e in [ArgumentError, ErlangError, FunctionClauseError] ->
      {:error,
       %ProviderError{
         class: :temporary,
         code: :connect_failed,
         message: "IMAP connect failed: #{Exception.message(e)}"
       }}
  end

  defp resolve_imap_account(nil, address), do: Accounts.ensure_account_for_address(address)

  defp resolve_imap_account(account_id, _address) when is_binary(account_id) do
    case Accounts.get_account(account_id) do
      nil -> {:error, Error.new(:permanent, :account_not_found, "account not found")}
      account -> {:ok, account}
    end
  end

  @spec get_account(Ecto.UUID.t()) :: {:ok, View.ReceiveMethod.t()} | {:error, Error.t()}
  def get_account(account_id) do
    case Repo.get(ReceiveMethod, account_id) do
      %ReceiveMethod{} = account -> {:ok, account_view(account)}
      nil -> {:error, Error.new(:permanent, :account_not_found, "connector account not found")}
    end
  rescue
    DBConnection.ConnectionError -> {:error, database_error(:unavailable)}
  end

  @spec list_activity_dates(Ecto.UUID.t()) :: {:ok, [Date.t()]} | {:error, :invalid_account_id}
  def list_activity_dates(account_id), do: ActivityLog.list_dates(account_id)

  @spec read_activity(Ecto.UUID.t(), Date.t(), pos_integer()) ::
          {:ok, [map()]} | {:error, :invalid_account_id}
  def read_activity(account_id, date, limit \\ 200),
    do: ActivityLog.read(account_id, date, limit)

  @spec enqueue_sync(Ecto.UUID.t()) :: {:ok, Oban.Job.t()} | {:error, Error.t() | term()}
  def enqueue_sync(account_id) do
    Repo.transaction(fn ->
      account =
        ReceiveMethod
        |> where([account], account.id == ^account_id)
        |> lock("FOR UPDATE")
        |> Repo.one()

      case account do
        %ReceiveMethod{status: "disconnected"} ->
          Repo.rollback(
            Error.new(:permanent, :account_disconnected, "receive method is disconnected")
          )

        %ReceiveMethod{enabled: false} ->
          Repo.rollback(Error.new(:permanent, :sync_disabled, "receive method is not enabled"))

        %ReceiveMethod{sync_enabled: true} ->
          ensure_sync_job(Repo, account_id)

        %ReceiveMethod{} ->
          Repo.rollback(
            Error.new(:permanent, :sync_disabled, "connector synchronization is disabled")
          )

        nil ->
          Repo.rollback(Error.new(:permanent, :account_not_found, "connector account not found"))
      end
    end)
  rescue
    DBConnection.ConnectionError -> {:error, database_error(:unavailable)}
  end

  @doc false
  @spec enqueue_due_syncs() :: {:ok, non_neg_integer()} | {:error, Error.t() | term()}
  def enqueue_due_syncs do
    Repo.transaction(fn ->
      account_ids =
        ReceiveMethod
        |> where(
          [account],
          account.enabled and account.sync_enabled and
            account.status in ["connected", "syncing", "failed"] and
            account.kind in ^ReceiveMethod.implemented_kinds()
        )
        |> order_by([account], asc: account.id)
        |> select([account], account.id)
        |> Repo.all()

      Enum.each(account_ids, &ensure_sync_job(Repo, &1))
      length(account_ids)
    end)
  rescue
    DBConnection.ConnectionError -> {:error, database_error(:unavailable)}
  end

  @spec disconnect(Ecto.UUID.t()) ::
          {:ok, ReceiveMethod.t()} | {:error, Error.t() | Ecto.Changeset.t()}
  def disconnect(account_id) do
    now = DateTime.utc_now()

    Multi.new()
    |> Multi.run(:account, fn repo, _changes ->
      account =
        ReceiveMethod
        |> where([account], account.id == ^account_id)
        |> lock("FOR UPDATE")
        |> repo.one()

      case account do
        nil ->
          {:error, Error.new(:permanent, :account_not_found, "connector account not found")}

        %ReceiveMethod{status: "disconnected"} = disconnected ->
          {:ok, disconnected}

        %ReceiveMethod{} = account ->
          account
          |> ReceiveMethod.changeset(%{
            status: "disconnected",
            enabled: false,
            sync_enabled: false,
            disconnected_at: now,
            last_error_class: nil,
            last_error_code: nil,
            last_error_message: nil
          })
          |> repo.update()
      end
    end)
    |> Multi.delete_all(
      :credentials,
      from(credential in Credential, where: credential.external_account_id == ^account_id)
    )
    |> Multi.insert(:event, fn %{account: account} ->
      ConnectorEvent.changeset(%ConnectorEvent{}, %{
        external_account_id: account.id,
        event_type: "disconnected",
        metadata: %{},
        occurred_at: now
      })
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{account: account}} -> {:ok, account}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  rescue
    DBConnection.ConnectionError -> {:error, database_error(:unavailable)}
  end

  @doc false
  @spec sync_account(Ecto.UUID.t(), Keyword.t()) ::
          :ok | {:snooze, pos_integer()} | {:cancel, atom()} | {:error, term()}
  def sync_account(account_id, opts \\ []), do: Sync.run(account_id, opts)

  @doc false
  @spec apply_remote_state(Ecto.UUID.t()) :: :ok | {:error, Error.t()}
  def apply_remote_state(remote_message_id) do
    query =
      from(remote in RemoteMessage,
        join: account in ReceiveMethod,
        on: account.id == remote.external_account_id,
        where: remote.id == ^remote_message_id,
        select: {remote, account}
      )

    case Repo.one(query) do
      {%RemoteMessage{inbound_delivery_id: nil}, %ReceiveMethod{}} ->
        :ok

      {%RemoteMessage{} = remote, %ReceiveMethod{} = account} ->
        account.account_id
        |> Mail.apply_external_state(remote.inbound_delivery_id, %{
          folder_kind: normalize_folder_kind(remote.remote_folder_kind),
          read?: remote.remote_read,
          starred?: remote.remote_starred,
          deleted?: remote.remote_deleted
        })
        |> case do
          {:ok, :applied} -> :ok
          {:error, %Error{} = error} -> {:error, error}
        end

      nil ->
        {:error,
         Error.new(:permanent, :remote_message_not_found, "connector message was not found")}
    end
  rescue
    DBConnection.ConnectionError -> {:error, database_error(:unavailable)}
  end

  defp persist_authorization(provider, consumed, token, identity, cursors, now, opts) do
    Multi.new()
    |> Multi.run(:account, fn repo, _changes ->
      upsert_account(repo, provider, consumed.mailbox_id, identity, token.scopes)
    end)
    |> Multi.run(:credential, fn repo, %{account: account} ->
      upsert_credential(repo, account.id, token)
    end)
    |> Multi.run(:cursors, fn repo, %{account: account} ->
      replace_cursors(repo, account.id, cursors, now)
    end)
    |> Multi.insert(:event, fn %{account: account} ->
      ConnectorEvent.changeset(%ConnectorEvent{}, %{
        external_account_id: account.id,
        event_type: "connected",
        metadata: %{provider: provider},
        occurred_at: now
      })
    end)
    |> Multi.run(:fault_boundary, fn _repo, _changes ->
      maybe_fault(opts, :after_credentials_before_job)
    end)
    |> Multi.run(:job, fn repo, %{account: account} ->
      {:ok, ensure_sync_job(repo, account.id)}
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{account: account}} -> {:ok, account}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  defp upsert_account(repo, provider, mailbox_id, identity, scopes) do
    existing =
      ReceiveMethod
      |> where(
        [account],
        account.kind == ^provider and account.provider_account_id == ^identity.id
      )
      |> lock("FOR UPDATE")
      |> repo.one()

    attrs = %{
      account_id: mailbox_id,
      kind: provider,
      provider_account_id: identity.id,
      email_address: identity.email_address,
      status: "connected",
      enabled: true,
      sync_enabled: true,
      granted_scopes: Enum.sort(scopes),
      disconnected_at: nil,
      last_error_class: nil,
      last_error_code: nil,
      last_error_message: nil
    }

    case existing do
      nil ->
        disable_other_methods(repo, mailbox_id)

        ReceiveMethod.changeset(%ReceiveMethod{}, attrs) |> repo.insert()

      %ReceiveMethod{account_id: ^mailbox_id} = account ->
        disable_other_methods(repo, mailbox_id, except_id: account.id)
        ReceiveMethod.changeset(account, Map.put(attrs, :enabled, true)) |> repo.update()

      %ReceiveMethod{} ->
        {:error,
         Error.new(
           :permanent,
           :mailbox_reassignment_not_allowed,
           "provider account is already bound to a different account"
         )}
    end
  end

  defp disable_other_methods(repo, account_id, opts \\ []) do
    except_id = Keyword.get(opts, :except_id)

    query =
      ReceiveMethod
      |> where([m], m.account_id == ^account_id and m.enabled == true)

    query =
      if except_id do
        where(query, [m], m.id != ^except_id)
      else
        query
      end

    repo.update_all(query, set: [enabled: false, updated_at: DateTime.utc_now()])
  end

  defp upsert_credential(repo, account_id, token) do
    existing = repo.get_by(Credential, external_account_id: account_id)

    with {:ok, encrypted_access} <-
           Crypto.encrypt(token.access_token, credential_context(account_id, :access)),
         {:ok, encrypted_refresh} <-
           encrypted_refresh_token(token.refresh_token, existing, account_id) do
      attrs = %{
        external_account_id: account_id,
        key_version: 1,
        access_token_ciphertext: encrypted_access,
        refresh_token_ciphertext: encrypted_refresh,
        token_expires_at: token.expires_at
      }

      case existing do
        nil -> Credential.changeset(%Credential{}, attrs) |> repo.insert()
        credential -> Credential.changeset(credential, attrs) |> repo.update()
      end
    end
  end

  defp encrypted_refresh_token(refresh_token, _existing, account_id)
       when is_binary(refresh_token) and refresh_token != "" do
    Crypto.encrypt(refresh_token, credential_context(account_id, :refresh))
  end

  defp encrypted_refresh_token(nil, %Credential{} = existing, _account_id),
    do: {:ok, existing.refresh_token_ciphertext}

  defp encrypted_refresh_token(nil, nil, _account_id) do
    {:error,
     Error.new(
       :permanent,
       :missing_refresh_token,
       "provider did not return a refresh token for a new connection"
     )}
  end

  defp replace_cursors(repo, account_id, cursors, now) do
    from(cursor in SyncCursor, where: cursor.external_account_id == ^account_id)
    |> repo.delete_all()

    rows =
      Enum.map(cursors, fn cursor ->
        %{
          id: Ecto.UUID.generate(),
          external_account_id: account_id,
          scope: cursor.scope,
          phase: cursor.phase,
          bootstrap_cursor: cursor.bootstrap_cursor,
          page_cursor: cursor.page_cursor,
          committed_cursor: cursor.committed_cursor,
          metadata: cursor.metadata,
          generation: 1,
          inserted_at: now,
          updated_at: now
        }
      end)

    {_count, _rows} = repo.insert_all(SyncCursor, rows)
    {:ok, length(rows)}
  end

  defp ensure_sync_job(repo, account_id) do
    existing =
      Oban.Job
      |> where([job], job.worker == ^inspect(SyncAccount))
      |> where([job], job.state in ~w(available scheduled executing retryable suspended))
      |> where(
        [job],
        fragment("?->>'external_account_id' = ?", job.args, ^account_id)
      )
      |> order_by([job], asc: job.id)
      |> limit(1)
      |> repo.one()

    existing ||
      account_id
      |> then(&SyncAccount.new(%{"external_account_id" => &1}))
      |> repo.insert!()
  end

  defp validate_consumed(provider, %Consumed{provider: provider}), do: :ok

  defp validate_consumed(_provider, _consumed) do
    {:error, Error.new(:permanent, :oauth_provider_mismatch, "OAuth provider does not match")}
  end

  defp validate_granted_scopes(provider, scopes) when is_list(scopes) do
    granted = MapSet.new(scopes)
    required = Map.fetch!(@required_scopes, provider)

    if MapSet.subset?(required, granted) do
      :ok
    else
      {:error,
       Error.new(
         :permanent,
         :insufficient_provider_scope,
         "provider did not grant all required read-only scopes"
       )}
    end
  end

  defp validate_cursors(cursors) when is_list(cursors) and cursors != [] do
    if Enum.all?(cursors, &match?(%Manifold.Connectors.Provider.SyncCursor{}, &1)) do
      :ok
    else
      invalid_cursors()
    end
  end

  defp validate_cursors(_cursors), do: invalid_cursors()

  defp invalid_cursors do
    {:error,
     Error.new(:permanent, :invalid_provider_cursors, "provider returned invalid sync cursors")}
  end

  defp adapter_config(provider) when provider in ["gmail", "microsoft"] do
    key = String.to_existing_atom(provider)
    adapters = Application.get_env(:manifold_connectors, :adapters, [])
    providers = Application.get_env(:manifold_connectors, :providers, [])

    adapter =
      Keyword.get(adapters, key) ||
        case provider do
          "gmail" -> Manifold.Connectors.Provider.Gmail
          "microsoft" -> Manifold.Connectors.Provider.MicrosoftGraph
        end

    case Keyword.get(providers, key) do
      config when is_list(config) ->
        {:ok, adapter, config}

      _missing ->
        {:error, Error.new(:permanent, :provider_not_configured, "provider is not configured")}
    end
  end

  defp adapter_config(_provider) do
    {:error, Error.new(:permanent, :unsupported_provider, "provider is not supported")}
  end

  defp provider_opts(opts), do: Keyword.get(opts, :provider_opts, [])

  defp provider_error(%ProviderError{} = error) do
    class = if error.class == :temporary, do: :temporary, else: :permanent

    Error.new(class, error.code, error.message, %{
      provider_class: error.class,
      retry_after_seconds: error.retry_after_seconds
    })
  end

  defp account_view(account) do
    %View.ReceiveMethod{
      id: account.id,
      account_id: account.account_id,
      kind: account.kind,
      email_address: account.email_address,
      status: account.status,
      enabled: account.enabled,
      sync_enabled: account.sync_enabled,
      last_attempted_at: account.last_attempted_at,
      last_synced_at: account.last_synced_at,
      last_error: account.last_error_message
    }
  end

  defp normalize_folder_kind(folder_kind) when folder_kind in ~w(inbox archive trash),
    do: folder_kind

  defp normalize_folder_kind(_folder_kind), do: "archive"

  defp credential_context(account_id, kind), do: "credential:#{account_id}:#{kind}"

  defp imap_transport do
    Application.get_env(:manifold_connectors, :imap_transport, Client)
  end

  defp attr(attrs, key) when is_atom(key) do
    Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))
  end

  defp truthy?(value), do: value in [true, "true", 1, "1"]

  defp maybe_test_imap(_attrs, true), do: :ok

  defp maybe_test_imap(attrs, false) do
    case test_imap_connection(attrs) do
      :ok -> :ok
      {:error, %ProviderError{} = error} -> {:error, error}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp reject_duplicate_imap(email_canonical, provider_account_id) do
    conflict =
      ReceiveMethod
      |> where([account], account.status != "disconnected")
      |> where(
        [account],
        account.provider_account_id == ^provider_account_id or
          fragment("lower(?) = ?", account.email_address, ^email_canonical)
      )
      |> limit(1)
      |> Repo.one()

    case conflict do
      nil ->
        :ok

      %ReceiveMethod{} ->
        {:error,
         Error.new(
           :permanent,
           :account_already_connected,
           "an IMAP account for this address is already connected"
         )}
    end
  end

  defp imap_settings_from_attrs(attrs) do
    host = attr(attrs, :host)
    username = attr(attrs, :username) || attr(attrs, :email_address)
    password = attr(attrs, :password)
    tls_mode = attr(attrs, :tls_mode) || "ssl"
    mailbox_path = attr(attrs, :mailbox_path) || "INBOX"
    port = parse_port(attr(attrs, :port) || 993)

    cond do
      not is_binary(host) or host == "" ->
        {:error, Error.new(:permanent, :invalid_imap_settings, "IMAP host is required")}

      not is_binary(username) or username == "" ->
        {:error, Error.new(:permanent, :invalid_imap_settings, "IMAP username is required")}

      not is_binary(password) or password == "" ->
        {:error, Error.new(:permanent, :invalid_imap_settings, "IMAP password is required")}

      tls_mode not in ["ssl", "starttls"] ->
        {:error, Error.new(:permanent, :invalid_imap_settings, "IMAP tls_mode is invalid")}

      not is_integer(port) ->
        {:error, Error.new(:permanent, :invalid_imap_settings, "IMAP port is invalid")}

      true ->
        settings = %{
          host: host,
          port: port,
          tls_mode: tls_mode,
          username: username,
          password: password,
          mailbox_path: mailbox_path
        }

        fake = Application.get_env(:manifold_connectors, :imap_fake, %{})

        {:ok,
         settings
         |> Map.merge(if(is_map(fake), do: fake, else: %{}))
         |> maybe_merge_attr_fake(attrs)}
    end
  end

  defp normalize_imap_attrs(attrs) when is_map(attrs) do
    attrs
    |> maybe_put_trimmed(:host)
    |> maybe_put_trimmed(:username)
    |> maybe_put_trimmed(:email_address)
    |> maybe_put_trimmed(:mailbox_path)
    |> maybe_put_normalized_port()
  end

  defp maybe_put_trimmed(attrs, key) do
    case attr(attrs, key) do
      value when is_binary(value) -> put_attr(attrs, key, String.trim(value))
      _ -> attrs
    end
  end

  defp maybe_put_normalized_port(attrs) do
    case attr(attrs, :port) do
      nil -> attrs
      port -> put_attr(attrs, :port, parse_port(port))
    end
  end

  defp put_attr(attrs, key, value) when is_map_key(attrs, key), do: Map.put(attrs, key, value)

  defp put_attr(attrs, key, value) do
    string_key = Atom.to_string(key)

    cond do
      is_map_key(attrs, string_key) -> Map.put(attrs, string_key, value)
      true -> Map.put(attrs, key, value)
    end
  end

  defp maybe_merge_attr_fake(settings, attrs) do
    case attr(attrs, :fake) do
      %{} = fake -> Map.merge(settings, fake)
      _ -> settings
    end
  end

  defp parse_port(port) when is_integer(port) and port > 0 and port <= 65_535, do: port

  defp parse_port(port) when is_binary(port) do
    case Integer.parse(String.trim(port)) do
      {value, ""} when value > 0 and value <= 65_535 -> value
      _ -> nil
    end
  end

  defp parse_port(_), do: nil

  defp imap_provider_config(attrs) do
    [
      host: attr(attrs, :host),
      port: parse_port(attr(attrs, :port) || 993),
      tls_mode: attr(attrs, :tls_mode) || "ssl",
      username: attr(attrs, :username) || attr(attrs, :email_address),
      mailbox_path: attr(attrs, :mailbox_path) || "INBOX",
      transport: imap_transport()
    ]
  end

  defp persist_imap_account(attrs, parsed, provider_account_id, mailbox, cursors, now) do
    password = attr(attrs, :password)
    username = attr(attrs, :username) || parsed.canonical
    host = attr(attrs, :host)
    port = parse_port(attr(attrs, :port) || 993)
    tls_mode = attr(attrs, :tls_mode) || "ssl"
    mailbox_path = attr(attrs, :mailbox_path) || "INBOX"

    Multi.new()
    |> Multi.run(:disable_others, fn repo, _changes ->
      disable_other_methods(repo, mailbox.id)
      {:ok, :ok}
    end)
    |> Multi.insert(:account, fn _changes ->
      ReceiveMethod.changeset(%ReceiveMethod{}, %{
        account_id: mailbox.id,
        kind: "imap",
        provider_account_id: provider_account_id,
        email_address: parsed.canonical,
        status: "connected",
        enabled: true,
        sync_enabled: true,
        granted_scopes: []
      })
    end)
    |> Multi.run(:credential, fn repo, %{account: account} ->
      with {:ok, ciphertext} <-
             Crypto.encrypt(password, credential_context(account.id, :imap_password)) do
        Credential.changeset(%Credential{}, %{
          external_account_id: account.id,
          key_version: 1,
          secret_kind: "password",
          password_ciphertext: ciphertext,
          refresh_token_ciphertext: nil
        })
        |> repo.insert()
      end
    end)
    |> Multi.insert(:imap_settings, fn %{account: account} ->
      ImapSettings.changeset(%ImapSettings{}, %{
        external_account_id: account.id,
        host: host,
        port: port,
        tls_mode: tls_mode,
        username: username,
        mailbox_path: mailbox_path
      })
    end)
    |> Multi.run(:cursors, fn repo, %{account: account} ->
      replace_cursors(repo, account.id, cursors, now)
    end)
    |> Multi.insert(:event, fn %{account: account} ->
      ConnectorEvent.changeset(%ConnectorEvent{}, %{
        external_account_id: account.id,
        event_type: "connected",
        metadata: %{provider: "imap"},
        occurred_at: now
      })
    end)
    |> Multi.run(:job, fn repo, %{account: account} ->
      {:ok, ensure_sync_job(repo, account.id)}
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{account: account}} -> {:ok, account}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  defp maybe_fault(opts, point) do
    if Keyword.get(opts, :fail_at) == point do
      {:error, Error.new(:temporary, point, "injected connector fault")}
    else
      {:ok, :ok}
    end
  end

  defp database_error(reason) do
    Error.new(:temporary, :database_unavailable, "connector database operation failed", %{
      reason: inspect(reason)
    })
  end
end
