defmodule Manifold.Connectors do
  @moduledoc """
  External mailbox account and synchronization context.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias Manifold.Accounts
  alias Manifold.Accounts.Schema.Account
  alias Manifold.Connectors.ActivityLog
  alias Manifold.Connectors.Crypto
  alias Manifold.Connectors.IMAP.Client
  alias Manifold.Connectors.EAS.Client, as: EASClient
  alias Manifold.Connectors.SMTP.Client, as: SmtpClient
  alias Manifold.Connectors.Jobs.{ApplyRemoteState, PushRemoteRead, SyncAccount}
  alias Manifold.Connectors.OAuth.Consumed
  alias Manifold.Connectors.OAuthAuthorizations
  alias Manifold.Connectors.OAuthScopes
  alias Manifold.Connectors.ProviderConfig
  alias Manifold.Connectors.ProviderSettings
  alias Manifold.Connectors.Provider.Error, as: ProviderError
  alias Manifold.Connectors.Provider.IMAP, as: ProviderIMAP
  alias Manifold.Connectors.Provider.EAS, as: ProviderEAS
  alias Manifold.Connectors.Sync
  alias Manifold.Connectors.SubmissionMethod

  alias Manifold.Connectors.Schema.{
    ConnectorEvent,
    Credential,
    OAuthAuthorization,
    ReceiveMethod,
    EasSettings,
    ImapSettings,
    OAuthTransaction,
    RemoteMessage,
    SendCredential,
    SendMethod,
    SmtpSettings,
    SyncCursor
  }

  alias Manifold.Connectors.View
  alias Manifold.Core.{Address, Error}
  alias Manifold.Mail
  alias Manifold.Mail.Schema.MailboxEntry
  alias Manifold.Repo

  @spec list_oauth_provider_settings() ::
          {:ok, [ProviderSettings.safe_view()]} | {:error, Error.t()}
  def list_oauth_provider_settings, do: ProviderSettings.list()

  @spec get_oauth_provider_setting(String.t()) ::
          {:ok, ProviderSettings.safe_view()} | {:error, Error.t()}
  def get_oauth_provider_setting(provider), do: ProviderSettings.get(provider)

  @spec change_oauth_provider_setting(String.t(), map()) ::
          Ecto.Changeset.t() | {:error, Error.t()}
  def change_oauth_provider_setting(provider, attrs \\ %{}),
    do: ProviderSettings.change(provider, attrs)

  @spec put_oauth_provider_setting(String.t(), map(), Keyword.t()) ::
          {:ok, ProviderSettings.safe_view()} | {:error, Error.t() | Ecto.Changeset.t()}
  def put_oauth_provider_setting(provider, attrs, opts \\ []),
    do: ProviderSettings.put(provider, attrs, opts)

  @spec remove_oauth_provider_setting(String.t(), Keyword.t()) ::
          {:ok, ProviderSettings.safe_view()} | {:error, Error.t() | Ecto.Changeset.t()}
  def remove_oauth_provider_setting(provider, opts \\ []),
    do: ProviderSettings.remove(provider, opts)

  @spec complete_authorization(String.t(), String.t(), Consumed.t(), Keyword.t()) ::
          {:ok, ReceiveMethod.t() | SendMethod.t()}
          | {:error, Error.t() | Ecto.Changeset.t()}
  def complete_authorization(provider, code, consumed, opts \\ [])

  def complete_authorization(provider, code, %Consumed{} = consumed, opts)
      when provider in ["gmail", "microsoft"] do
    provider_opts =
      opts
      |> provider_opts()
      |> Keyword.put(:required_scopes, consumed.required_scopes)

    with :ok <- validate_consumed(provider, consumed),
         {:ok, adapter, config, generation_opts} <-
           completion_adapter_config(provider, consumed) do
      OAuthAuthorizations.complete(
        provider,
        code,
        consumed,
        adapter,
        config,
        opts
        |> Keyword.put(:provider_opts, provider_opts)
        |> Keyword.merge(generation_opts)
      )
    end
  rescue
    DBConnection.ConnectionError ->
      {:error, database_error(:unavailable)}
  end

  def complete_authorization(_provider, _code, %Consumed{}, _opts) do
    {:error, Error.new(:permanent, :unsupported_provider, "provider is not supported")}
  rescue
    DBConnection.ConnectionError ->
      {:error, database_error(:unavailable)}
  end

  @spec checkout_oauth_access_token(Ecto.UUID.t(), Keyword.t()) ::
          {:ok, term()} | {:error, Error.t() | ProviderError.t() | Ecto.Changeset.t()}
  def checkout_oauth_access_token(authorization_id, opts \\ []) do
    with {:ok, authorization_id, provider} <- oauth_authorization_provider(authorization_id),
         {:ok, adapter, config} <- adapter_config(provider) do
      OAuthAuthorizations.checkout_access_token(
        authorization_id,
        adapter,
        config,
        opts
      )
    end
  rescue
    DBConnection.ConnectionError ->
      {:error, database_error(:unavailable)}
  end

  @doc false
  @spec checkout_resolved_oauth_access_token(
          Ecto.UUID.t(),
          String.t(),
          module(),
          keyword(),
          Keyword.t()
        ) :: {:ok, term()} | {:error, Error.t() | ProviderError.t() | Ecto.Changeset.t()}
  def checkout_resolved_oauth_access_token(
        authorization_id,
        expected_provider,
        adapter,
        config,
        opts \\ []
      )
      when expected_provider in ["gmail", "microsoft"] and is_atom(adapter) and
             is_list(config) do
    with {:ok, authorization_id, ^expected_provider} <-
           oauth_authorization_provider(authorization_id) do
      OAuthAuthorizations.checkout_access_token(
        authorization_id,
        adapter,
        config,
        opts
      )
    else
      {:ok, _authorization_id, _other_provider} -> invalid_oauth_authorization()
      {:error, %Error{} = error} -> {:error, error}
    end
  rescue
    DBConnection.ConnectionError ->
      {:error, database_error(:unavailable)}
  end

  @spec mark_oauth_reconnect_required(Ecto.UUID.t(), ProviderError.t(), Keyword.t()) ::
          {:ok, OAuthAuthorization.t()}
          | {:error, Error.t() | Ecto.Changeset.t()}
  def mark_oauth_reconnect_required(authorization_id, %ProviderError{} = error, opts \\ []) do
    OAuthAuthorizations.mark_reconnect_required(authorization_id, error, opts)
  end

  @spec mark_oauth_send_reconnect_required(Ecto.UUID.t(), String.t(), atom(), Keyword.t()) ::
          {:ok, :marked | :already_marked | :stale | :inactive, OAuthAuthorization.t()}
          | {:error, Error.t() | Ecto.Changeset.t()}
  def mark_oauth_send_reconnect_required(method_id, expected_access_token, error_code, opts \\ []) do
    OAuthAuthorizations.mark_send_reconnect_required(
      method_id,
      expected_access_token,
      error_code,
      opts
    )
  end

  @doc false
  def mark_gmail_send_reconnect_required(method_id, expected_access_token, error_code, opts \\ []) do
    mark_oauth_send_reconnect_required(method_id, expected_access_token, error_code, opts)
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
      mailbox_id =
        ReceiveMethod
        |> where([m], m.id == ^receive_method_id)
        |> select([m], m.account_id)
        |> Repo.one()

      case mailbox_id do
        nil ->
          Repo.rollback(Error.new(:permanent, :account_not_found, "receive method not found"))

        mailbox_id ->
          case ensure_active_mailbox(Repo, mailbox_id) do
            {:ok, _mailbox} ->
              case lock_receive_method(Repo, receive_method_id) do
                nil ->
                  Repo.rollback(
                    Error.new(:permanent, :account_not_found, "receive method not found")
                  )

                method ->
                  enable_receive_method(Repo, method)
              end

            {:error, reason} ->
              Repo.rollback(reason)
          end
      end
    end)
  rescue
    DBConnection.ConnectionError -> {:error, database_error(:unavailable)}
  end

  @spec create_placeholder_receive_method(Ecto.UUID.t(), String.t(), map()) ::
          {:ok, ReceiveMethod.t()} | {:error, Error.t() | Ecto.Changeset.t()}
  def create_placeholder_receive_method(account_id, kind, attrs \\ %{})
      when kind in ["pop3", "ews"] do
    email =
      Map.get(attrs, :email_address) || Map.get(attrs, "email_address") ||
        case Accounts.get_account(account_id) do
          nil -> nil
          account -> Accounts.account_address(account)
        end

    if is_nil(email) do
      {:error, Error.new(:permanent, :account_not_found, "account not found")}
    else
      changeset =
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

      Repo.transaction(fn ->
        with {:ok, _mailbox} <- ensure_active_mailbox(Repo, account_id),
             {:ok, method} <- Repo.insert(changeset) do
          method
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end
  end

  @spec configured_providers() :: [String.t()]
  def configured_providers do
    ["gmail", "microsoft"]
    |> Enum.filter(&match?({:ok, %ProviderConfig.Resolved{}}, ProviderConfig.fetch(&1)))
  end

  @spec oauth_method_setup(Ecto.UUID.t(), String.t(), :receive | :send) ::
          {:ok, View.OAuthMethodSetup.t()} | {:error, Error.t()}
  def oauth_method_setup(account_id, provider, purpose) do
    with {:ok, account_id} <- cast_oauth_account_id(account_id),
         {:ok, required_scope} <- oauth_method_scope(provider, purpose),
         {:ok, sender} <- Accounts.get_sender_identity(account_id) do
      authorization =
        Repo.get_by(OAuthAuthorization, account_id: account_id, provider: provider)

      {:ok,
       %View.OAuthMethodSetup{
         provider: provider,
         purpose: purpose,
         state:
           oauth_method_setup_state(
             authorization,
             purpose,
             required_scope,
             sender.canonical_address
           )
       }}
    end
  rescue
    DBConnection.ConnectionError -> {:error, database_error(:unavailable)}
  end

  @spec add_authorized_oauth_method(Ecto.UUID.t(), String.t(), :receive | :send) ::
          {:ok, ReceiveMethod.t() | SendMethod.t()}
          | {:error, Error.t() | Ecto.Changeset.t()}
  def add_authorized_oauth_method(account_id, provider, purpose) do
    with {:ok, account_id} <- cast_oauth_account_id(account_id),
         {:ok, _required_scope} <- oauth_method_scope(provider, purpose),
         {:ok, adapter, config} <- adapter_config(provider) do
      provider
      |> OAuthAuthorizations.add_authorized_method(
        account_id,
        purpose,
        adapter,
        config,
        []
      )
      |> normalize_authorized_method_result()
    end
  rescue
    DBConnection.ConnectionError -> {:error, database_error(:unavailable)}
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

  @spec test_eas_connection(map()) :: :ok | {:error, Error.t() | ProviderError.t()}
  def test_eas_connection(attrs) when is_map(attrs) do
    attrs = normalize_eas_attrs(attrs)

    with {:ok, settings} <- eas_settings_from_attrs(attrs),
         {:ok, _discovered} <- discover_eas(settings) do
      :ok
    end
  rescue
    e in [ArgumentError, ErlangError, FunctionClauseError] ->
      {:error,
       %ProviderError{
         class: :temporary,
         code: :connect_failed,
         message: "EAS connect failed: #{Exception.message(e)}"
       }}
  end

  @spec create_eas_account(map()) ::
          {:ok, ReceiveMethod.t()}
          | {:error, Error.t() | Ecto.Changeset.t() | ProviderError.t()}
  def create_eas_account(attrs) when is_map(attrs) do
    attrs = normalize_eas_attrs(attrs)
    now = DateTime.utc_now()
    account_id = attr(attrs, :account_id)

    with {:ok, parsed} <- Address.parse(attr(attrs, :email_address) || ""),
         provider_account_id <- "eas:" <> parsed.canonical,
         :ok <- reject_duplicate_eas(parsed.canonical, provider_account_id),
         {:ok, settings} <- eas_settings_from_attrs(attrs),
         {:ok, discovered} <- discover_eas(settings),
         {:ok, mailbox} <- resolve_imap_account(account_id, parsed.canonical),
         {:ok, cursors} <-
           ProviderEAS.initial_cursors(
             attr(attrs, :password),
             eas_provider_config(attrs, discovered),
             []
           ) do
      persist_eas_account(attrs, parsed, provider_account_id, mailbox, cursors, discovered, now)
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
         message: "EAS connect failed: #{Exception.message(e)}"
       }}
  end

  @spec list_send_methods_for_account(Ecto.UUID.t()) :: [View.SendMethod.t()]
  def list_send_methods_for_account(account_id) do
    SendMethod
    |> where([m], m.account_id == ^account_id)
    |> order_by([m], desc: m.enabled, asc: m.kind, asc: m.id)
    |> Repo.all()
    |> Enum.map(&send_method_view/1)
  end

  @spec enabled_send_method(Ecto.UUID.t()) ::
          {:ok, SubmissionMethod.t()} | {:error, Error.t()}
  def enabled_send_method(account_id) do
    SendMethod
    |> where(
      [method],
      method.account_id == ^account_id and method.enabled == true and
        method.status == "connected"
    )
    |> lock("FOR UPDATE")
    |> Repo.one()
    |> case do
      %SendMethod{} = method -> {:ok, submission_method(method)}
      nil -> {:error, send_method_required()}
    end
  rescue
    DBConnection.ConnectionError -> {:error, database_error(:unavailable)}
  end

  @spec checkout_send_method(Ecto.UUID.t(), String.t(), Keyword.t()) ::
          {:ok, SubmissionMethod.t()}
          | {:error, Error.t() | ProviderError.t() | Ecto.Changeset.t()}
  def checkout_send_method(method_id, required_sender, opts \\ []) do
    with {:ok, parsed_sender} <- Address.parse(required_sender),
         {:ok, method} <- preflight_send_method(method_id, parsed_sender) do
      case method.kind do
        provider when provider in ["gmail", "microsoft"] ->
          checkout_oauth_send_method(method, parsed_sender, opts)

        "smtp" ->
          checkout_smtp_send_method(method, parsed_sender)

        _unsupported ->
          {:error, send_method_required()}
      end
    end
  rescue
    DBConnection.ConnectionError -> {:error, database_error(:unavailable)}
  end

  @spec test_smtp_connection(map()) :: :ok | {:error, Error.t() | ProviderError.t()}
  def test_smtp_connection(attrs) when is_map(attrs) do
    attrs = normalize_smtp_attrs(attrs)

    with {:ok, settings} <- smtp_settings_from_attrs(attrs) do
      transport = smtp_transport()

      case transport.connect(settings) do
        {:ok, conn} ->
          transport.quit(conn)
          :ok

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
         message: "SMTP connect failed: #{Exception.message(e)}"
       }}
  end

  @spec create_smtp_send_method(map()) ::
          {:ok, SendMethod.t()}
          | {:error, Error.t() | Ecto.Changeset.t() | ProviderError.t()}
  def create_smtp_send_method(attrs) when is_map(attrs) do
    attrs = normalize_smtp_attrs(attrs)
    now = DateTime.utc_now()
    skip_test? = truthy?(attr(attrs, :skip_test))
    account_id = attr(attrs, :account_id)

    with {:ok, parsed} <- Address.parse(attr(attrs, :email_address) || ""),
         {:ok, mailbox} <- resolve_send_account(account_id),
         :ok <- require_account_sender(parsed, mailbox),
         :ok <- maybe_test_smtp(attrs, skip_test?) do
      persist_smtp_send_method(attrs, parsed, mailbox, now)
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
         message: "SMTP connect failed: #{Exception.message(e)}"
       }}
  end

  @spec enable_send_method(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, SendMethod.t()} | {:error, Error.t() | Ecto.Changeset.t()}
  def enable_send_method(account_id, send_method_id) do
    Repo.transaction(fn ->
      mailbox_id =
        SendMethod
        |> where([m], m.id == ^send_method_id and m.account_id == ^account_id)
        |> select([m], m.account_id)
        |> Repo.one()

      case mailbox_id do
        nil ->
          Repo.rollback(Error.new(:permanent, :account_not_found, "send method not found"))

        mailbox_id ->
          case ensure_active_mailbox(Repo, mailbox_id) do
            {:ok, _mailbox} ->
              case lock_send_method(Repo, send_method_id) do
                nil ->
                  Repo.rollback(
                    Error.new(:permanent, :account_not_found, "send method not found")
                  )

                method ->
                  enable_locked_send_method(Repo, method)
              end

            {:error, reason} ->
              Repo.rollback(reason)
          end
      end
    end)
  rescue
    DBConnection.ConnectionError -> {:error, database_error(:unavailable)}
  end

  @spec disconnect_send_method(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, SendMethod.t()} | {:error, Error.t() | Ecto.Changeset.t()}
  def disconnect_send_method(account_id, send_method_id) do
    case Repo.get_by(SendMethod, id: send_method_id, account_id: account_id) do
      %SendMethod{kind: provider, oauth_authorization_id: authorization_id}
      when provider in ["gmail", "microsoft"] and is_binary(authorization_id) ->
        OAuthAuthorizations.disconnect_method(:send, account_id, send_method_id)

      _method ->
        disconnect_legacy_send_method(account_id, send_method_id)
    end
  rescue
    DBConnection.ConnectionError -> {:error, database_error(:unavailable)}
  end

  defp disconnect_legacy_send_method(account_id, send_method_id) do
    now = DateTime.utc_now()

    Multi.new()
    |> Multi.run(:method, fn repo, _changes ->
      method =
        SendMethod
        |> where([m], m.id == ^send_method_id and m.account_id == ^account_id)
        |> lock("FOR UPDATE")
        |> repo.one()

      case method do
        nil ->
          {:error, Error.new(:permanent, :account_not_found, "send method not found")}

        %SendMethod{status: "disconnected"} = disconnected ->
          {:ok, disconnected}

        %SendMethod{} = method ->
          method
          |> SendMethod.changeset(%{
            status: "disconnected",
            enabled: false,
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
      from(c in SendCredential, where: c.send_method_id == ^send_method_id)
    )
    |> Multi.delete_all(
      :settings,
      from(s in SmtpSettings, where: s.send_method_id == ^send_method_id)
    )
    |> Repo.transaction()
    |> case do
      {:ok, %{method: method}} -> {:ok, method}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
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

  @spec sync_job_running?(Ecto.UUID.t()) :: boolean()
  def sync_job_running?(account_id) when is_binary(account_id) do
    match?(%Oban.Job{}, incomplete_sync_job(Repo, account_id))
  end

  @spec enqueue_sync(Ecto.UUID.t()) :: {:ok, Oban.Job.t()} | {:error, Error.t() | term()}
  def enqueue_sync(account_id) do
    Repo.transaction(fn ->
      mailbox_id =
        ReceiveMethod
        |> where([account], account.id == ^account_id)
        |> select([account], account.account_id)
        |> Repo.one()

      case mailbox_id do
        nil ->
          Repo.rollback(Error.new(:permanent, :account_not_found, "connector account not found"))

        mailbox_id ->
          case ensure_active_mailbox(Repo, mailbox_id) do
            {:ok, _mailbox} ->
              case lock_receive_method(Repo, account_id) do
                nil ->
                  Repo.rollback(
                    Error.new(:permanent, :account_not_found, "connector account not found")
                  )

                account ->
                  enqueue_sync(Repo, account)
              end

            {:error, reason} ->
              Repo.rollback(reason)
          end
      end
    end)
  rescue
    DBConnection.ConnectionError -> {:error, database_error(:unavailable)}
  end

  @doc false
  @spec enqueue_due_syncs() :: {:ok, non_neg_integer()} | {:error, Error.t() | term()}
  @spec enqueue_due_syncs(Keyword.t()) ::
          {:ok, non_neg_integer()} | {:error, Error.t() | term()}
  def enqueue_due_syncs(opts \\ []) do
    Repo.transaction(fn ->
      candidate_mailbox_ids = due_mailbox_ids(Repo)
      maybe_before_locked_recheck(opts)

      active_mailbox_ids = lock_active_mailboxes(Repo, candidate_mailbox_ids, :skip_inactive)
      account_ids = due_receive_method_ids(Repo, active_mailbox_ids)

      Enum.each(account_ids, &ensure_sync_job(Repo, &1))
      length(account_ids)
    end)
  rescue
    DBConnection.ConnectionError -> {:error, database_error(:unavailable)}
  end

  @doc false
  @spec quiesce_account(module(), Ecto.UUID.t()) ::
          {:ok, %{receive_methods: non_neg_integer(), send_methods: non_neg_integer()}}
  def quiesce_account(repo, mailbox_id) do
    now = DateTime.utc_now()

    {receive_count, _} =
      ReceiveMethod
      |> where([method], method.account_id == ^mailbox_id)
      |> repo.update_all(set: [enabled: false, sync_enabled: false, updated_at: now])

    {send_count, _} =
      SendMethod
      |> where([method], method.account_id == ^mailbox_id)
      |> repo.update_all(set: [enabled: false, updated_at: now])

    {:ok, %{receive_methods: receive_count, send_methods: send_count}}
  end

  @doc false
  @spec cancel_account_jobs(Ecto.UUID.t(), pos_integer()) ::
          {:snooze, 5} | %{cancelled: non_neg_integer(), done?: boolean()}
  def cancel_account_jobs(mailbox_id, limit) when is_integer(limit) and limit > 0 do
    {:ok, result} =
      Repo.transaction(fn ->
        matching = account_job_query(mailbox_id)

        selected =
          matching
          |> order_by([job], asc: job.id)
          |> limit(^limit)
          |> lock("FOR UPDATE SKIP LOCKED")
          |> select([job], {job.id, job.state})
          |> Repo.all()

        executing_ids = for {id, "executing"} <- selected, do: id
        drainable_ids = for {id, state} <- selected, state != "executing", do: id

        drained = delete_account_jobs(Repo, drainable_ids)
        cancelled = cancel_executing_account_jobs(executing_ids)

        matching_executing? =
          matching
          |> where([job], job.state == "executing")
          |> Repo.exists?()

        if executing_ids != [] or matching_executing? do
          {:snooze, 5}
        else
          %{cancelled: drained + cancelled, done?: not Repo.exists?(matching)}
        end
      end)

    result
  end

  @spec list_account_delivery_ids(Ecto.UUID.t(), Ecto.UUID.t() | nil, pos_integer()) :: %{
          ids: [Ecto.UUID.t()],
          next: Ecto.UUID.t() | nil,
          done?: boolean()
        }
  def list_account_delivery_ids(mailbox_id, after_id, limit)
      when is_integer(limit) and limit > 0 do
    query =
      RemoteMessage
      |> join(:inner, [remote], method in ReceiveMethod,
        on: method.id == remote.external_account_id
      )
      |> where(
        [remote, method],
        method.account_id == ^mailbox_id and not is_nil(remote.inbound_delivery_id)
      )

    query =
      if is_binary(after_id) do
        where(query, [remote, _method], remote.inbound_delivery_id > ^after_id)
      else
        query
      end

    ids =
      query
      |> distinct([remote, _method], remote.inbound_delivery_id)
      |> order_by([remote, _method], asc: remote.inbound_delivery_id)
      |> limit(^limit)
      |> select([remote, _method], remote.inbound_delivery_id)
      |> Repo.all()

    %{ids: ids, next: List.last(ids), done?: length(ids) < limit}
  end

  @spec delivery_owned?(Ecto.UUID.t()) :: boolean()
  def delivery_owned?(delivery_id) do
    RemoteMessage
    |> where([remote], remote.inbound_delivery_id == ^delivery_id)
    |> Repo.exists?()
  end

  @doc false
  @spec purge_account_batch(module(), Ecto.UUID.t(), pos_integer()) :: %{
          deleted: non_neg_integer(),
          done?: boolean(),
          activity_log_ids: [Ecto.UUID.t()]
        }
  def purge_account_batch(repo, mailbox_id, limit) when is_integer(limit) and limit > 0 do
    case next_purge_batch(repo, mailbox_id, limit) do
      {:remote_messages, ids} ->
        {deleted, _} =
          RemoteMessage
          |> where([remote], remote.id in ^ids)
          |> repo.delete_all()

        purge_result(repo, mailbox_id, deleted, [])

      {:receive_methods, ids} ->
        {deleted, _} =
          ReceiveMethod
          |> where([method], method.id in ^ids)
          |> repo.delete_all()

        purge_result(repo, mailbox_id, deleted, ids)

      {:send_methods, ids} ->
        {deleted, _} =
          SendMethod
          |> where([method], method.id in ^ids)
          |> repo.delete_all()

        purge_result(repo, mailbox_id, deleted, [])

      {:oauth_transactions, ids} ->
        {deleted, _} =
          OAuthTransaction
          |> where([transaction], transaction.id in ^ids)
          |> repo.delete_all()

        purge_result(repo, mailbox_id, deleted, [])

      :empty ->
        %{deleted: 0, done?: true, activity_log_ids: []}
    end
  end

  @spec account_data_remaining?(Ecto.UUID.t()) :: boolean()
  def account_data_remaining?(mailbox_id), do: account_data_remaining?(Repo, mailbox_id)

  @spec disconnect(Ecto.UUID.t()) ::
          {:ok, ReceiveMethod.t()} | {:error, Error.t() | Ecto.Changeset.t()}
  def disconnect(account_id) do
    case Repo.get(ReceiveMethod, account_id) do
      %ReceiveMethod{kind: provider, oauth_authorization_id: authorization_id}
      when provider in ["gmail", "microsoft"] and is_binary(authorization_id) ->
        OAuthAuthorizations.disconnect_method(:receive, account_id)

      _method ->
        disconnect_legacy_receive_method(account_id)
    end
  rescue
    DBConnection.ConnectionError -> {:error, database_error(:unavailable)}
  end

  defp disconnect_legacy_receive_method(account_id) do
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
  end

  @spec delete_receive_method(Ecto.UUID.t()) ::
          {:ok, ReceiveMethod.t()} | {:error, Error.t()}
  def delete_receive_method(method_id) do
    case Repo.get(ReceiveMethod, method_id) do
      %ReceiveMethod{kind: provider, oauth_authorization_id: authorization_id}
      when provider in ["gmail", "microsoft"] and is_binary(authorization_id) ->
        OAuthAuthorizations.delete_receive_method(method_id)

      _method ->
        delete_legacy_receive_method(method_id)
    end
  rescue
    DBConnection.ConnectionError -> {:error, database_error(:unavailable)}
  end

  defp delete_legacy_receive_method(method_id) do
    Multi.new()
    |> Multi.run(:method, fn repo, _changes ->
      method =
        ReceiveMethod
        |> where([method], method.id == ^method_id)
        |> lock("FOR UPDATE")
        |> repo.one()

      case method do
        nil ->
          {:error, Error.new(:permanent, :account_not_found, "receive method not found")}

        %ReceiveMethod{} = method ->
          {:ok, method}
      end
    end)
    |> Multi.run(:cancel_jobs, fn repo, %{method: method} ->
      {_count, _} =
        Oban.Job
        |> where([job], job.worker == ^inspect(SyncAccount))
        |> where([job], job.state in ~w(available scheduled retryable suspended))
        |> where(
          [job],
          fragment("?->>'external_account_id' = ?", job.args, ^method.id)
        )
        |> repo.delete_all()

      {:ok, true}
    end)
    |> Multi.delete(:deleted, fn %{method: method} -> method end)
    |> Repo.transaction()
    |> case do
      {:ok, %{deleted: method}} -> {:ok, method}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
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
        if match?(%DateTime{}, remote.provider_received_at) and
             is_binary(remote.inbound_delivery_id) do
          Mail.set_received_at(remote.inbound_delivery_id, remote.provider_received_at)
        end

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

  @doc """
  Enqueues remote read write-back jobs for local mailbox entries (IMAP and EAS).
  """
  @spec enqueue_read_push([Ecto.UUID.t()], boolean()) :: :ok | {:error, Error.t() | term()}
  def enqueue_read_push(entry_ids, read?)
      when is_list(entry_ids) and is_boolean(read?) do
    Repo.transaction(fn ->
      mailbox_ids = read_push_mailbox_ids(Repo, entry_ids)
      lock_active_mailboxes(Repo, mailbox_ids, :rollback_on_inactive)

      entry_ids
      |> read_push_remote_ids(Repo, mailbox_ids)
      |> lock_remote_messages(Repo)
      |> Enum.each(fn remote ->
        with {:ok, _remote} <-
               remote
               |> RemoteMessage.changeset(%{remote_read: read?})
               |> Repo.update(),
             {:ok, _job} <- replace_push_read_job(Repo, remote.id, read?) do
          :ok
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

      :ok
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    DBConnection.ConnectionError -> {:error, database_error(:unavailable)}
  end

  @doc false
  @spec enqueue_imap_read_push([Ecto.UUID.t()], boolean()) ::
          :ok | {:error, Error.t() | term()}
  def enqueue_imap_read_push(entry_ids, read?), do: enqueue_read_push(entry_ids, read?)

  @doc false
  @spec push_remote_read(Ecto.UUID.t(), boolean()) ::
          :ok | {:error, Error.t() | ProviderError.t()}
  def push_remote_read(remote_message_id, read?) when is_boolean(read?) do
    Sync.push_remote_read(remote_message_id, read?)
  end

  @doc false
  @spec push_imap_read(Ecto.UUID.t(), boolean()) ::
          :ok | {:error, Error.t() | ProviderError.t()}
  def push_imap_read(remote_message_id, read?), do: push_remote_read(remote_message_id, read?)

  defp replace_push_read_job(repo, remote_message_id, read?) do
    Oban.Job
    |> where([job], job.worker == ^inspect(PushRemoteRead))
    |> where([job], job.state in ~w(available scheduled retryable))
    |> where(
      [job],
      fragment("?->>'remote_message_id' = ?", job.args, ^remote_message_id)
    )
    |> repo.delete_all()

    %{"remote_message_id" => remote_message_id, "read" => read?}
    |> PushRemoteRead.new()
    |> repo.insert()
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
    incomplete_sync_job(repo, account_id) ||
      account_id
      |> then(&SyncAccount.new(%{"external_account_id" => &1}))
      |> repo.insert!()
  end

  defp incomplete_sync_job(repo, account_id) do
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
  end

  defp validate_consumed(provider, %Consumed{provider: provider}), do: :ok

  defp validate_consumed(_provider, _consumed) do
    {:error, Error.new(:permanent, :oauth_provider_mismatch, "OAuth provider does not match")}
  end

  defp cast_oauth_account_id(account_id) do
    case Ecto.UUID.cast(account_id) do
      {:ok, cast_id} -> {:ok, cast_id}
      :error -> {:error, Error.new(:permanent, :account_not_found, "account not found")}
    end
  end

  defp oauth_method_scope(provider, purpose)
       when provider in ["gmail", "microsoft"] and purpose in [:receive, :send] do
    case OAuthScopes.method_scope(provider, purpose) do
      {:ok, scope} -> {:ok, scope}
      :error -> unsupported_oauth_purpose()
    end
  end

  defp oauth_method_scope(provider, _purpose) when provider not in ["gmail", "microsoft"] do
    {:error, Error.new(:permanent, :unsupported_provider, "provider is not supported")}
  end

  defp oauth_method_scope(_provider, _purpose), do: unsupported_oauth_purpose()

  defp unsupported_oauth_purpose do
    {:error, Error.new(:permanent, :invalid_oauth_purpose, "OAuth purpose is invalid")}
  end

  defp oauth_method_setup_state(nil, _purpose, _required_scope, _canonical_sender), do: :connect

  defp oauth_method_setup_state(
         %OAuthAuthorization{status: "disconnected"},
         _purpose,
         _required_scope,
         _canonical_sender
       ),
       do: :connect

  defp oauth_method_setup_state(
         %OAuthAuthorization{status: "reconnect_required"},
         _purpose,
         _required_scope,
         _canonical_sender
       ),
       do: :reconnect

  defp oauth_method_setup_state(
         %OAuthAuthorization{status: "connected"} = authorization,
         purpose,
         required_scope,
         canonical_sender
       ) do
    cond do
      required_scope not in authorization.granted_scopes ->
        :upgrade

      live_oauth_method?(authorization, purpose, required_scope, canonical_sender) ->
        :connected

      true ->
        :add
    end
  end

  defp live_oauth_method?(authorization, :receive, required_scope, canonical_sender) do
    case Repo.get_by(ReceiveMethod,
           account_id: authorization.account_id,
           kind: authorization.provider,
           oauth_authorization_id: authorization.id
         ) do
      %ReceiveMethod{
        status: status,
        enabled: true,
        sync_enabled: true,
        granted_scopes: scopes
      } = method
      when status in ["connected", "syncing"] ->
        method_scopes = MapSet.new(scopes)

        method.provider_account_id == authorization.provider_subject_id and
          MapSet.member?(method_scopes, required_scope) and
          MapSet.subset?(method_scopes, MapSet.new(authorization.granted_scopes)) and
          oauth_method_addresses_match?(authorization, method.email_address, canonical_sender)

      _missing_or_inactive ->
        false
    end
  end

  defp live_oauth_method?(authorization, :send, _required_scope, canonical_sender) do
    case Repo.get_by(SendMethod,
           account_id: authorization.account_id,
           kind: authorization.provider,
           oauth_authorization_id: authorization.id
         ) do
      %SendMethod{status: "connected", enabled: true} = method ->
        oauth_method_addresses_match?(authorization, method.email_address, canonical_sender)

      _missing_or_inactive ->
        false
    end
  end

  defp oauth_method_addresses_match?(authorization, method_email, canonical_sender) do
    with {:ok, authorization_address} <- Address.parse(authorization.email_address),
         {:ok, method_address} <- Address.parse(method_email) do
      authorization_address.canonical == canonical_sender and
        method_address.canonical == canonical_sender
    else
      _invalid_address -> false
    end
  end

  defp normalize_authorized_method_result({:error, %ProviderError{} = error}) do
    class = if error.class == :temporary, do: :temporary, else: :permanent

    {:error,
     Error.new(class, error.code, error.message, %{
       provider_class: error.class,
       retry_after_seconds: error.retry_after_seconds
     })}
  end

  defp normalize_authorized_method_result(result), do: result

  defp adapter_config("gmail") do
    adapters = Application.get_env(:manifold_connectors, :adapters, [])

    adapter = Keyword.get(adapters, :gmail) || Manifold.Connectors.Provider.Gmail

    with {:ok, %ProviderConfig.Resolved{config: config}} <- ProviderConfig.fetch("gmail") do
      {:ok, adapter, config}
    end
  end

  defp adapter_config("microsoft") do
    adapters = Application.get_env(:manifold_connectors, :adapters, [])
    providers = Application.get_env(:manifold_connectors, :providers, [])

    adapter =
      Keyword.get(adapters, :microsoft) || Manifold.Connectors.Provider.MicrosoftGraph

    case Keyword.get(providers, :microsoft) do
      config when is_list(config) -> {:ok, adapter, config}
      _missing -> provider_not_configured()
    end
  end

  defp adapter_config(_provider) do
    {:error, Error.new(:permanent, :unsupported_provider, "provider is not supported")}
  end

  defp completion_adapter_config("gmail", %Consumed{} = consumed) do
    adapters = Application.get_env(:manifold_connectors, :adapters, [])

    adapter =
      Keyword.get(adapters, :gmail) || Manifold.Connectors.Provider.Gmail

    with {:ok, %ProviderConfig.Resolved{} = resolved} <- ProviderConfig.fetch("gmail"),
         :ok <- validate_completion_generation(consumed, resolved) do
      {:ok, adapter, resolved.config,
       expected_oauth_provider_setting_id: resolved.setting_id,
       expected_oauth_provider_setting_lock_version: resolved.setting_lock_version}
    else
      {:error, %Error{reason: reason}}
      when reason in [:provider_not_configured, :provider_configuration_error] ->
        provider_configuration_changed()

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp completion_adapter_config("microsoft", %Consumed{}) do
    case adapter_config("microsoft") do
      {:ok, adapter, config} -> {:ok, adapter, config, []}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp validate_completion_generation(
         %Consumed{
           provider: "gmail",
           oauth_provider_setting_id: setting_id,
           oauth_provider_setting_lock_version: setting_lock_version
         },
         %ProviderConfig.Resolved{
           provider: "gmail",
           setting_id: setting_id,
           setting_lock_version: setting_lock_version
         }
       )
       when is_binary(setting_id) and is_integer(setting_lock_version),
       do: :ok

  defp validate_completion_generation(
         %Consumed{
           provider: "gmail",
           oauth_provider_setting_id: nil,
           oauth_provider_setting_lock_version: nil
         },
         %ProviderConfig.Resolved{provider: "gmail"}
       ),
       do: :ok

  defp validate_completion_generation(
         %Consumed{provider: "gmail"},
         %ProviderConfig.Resolved{provider: "gmail"}
       ),
       do: provider_configuration_changed()

  defp validate_completion_generation(%Consumed{}, %ProviderConfig.Resolved{}), do: :ok

  defp provider_configuration_changed do
    {:error,
     Error.new(
       :permanent,
       :provider_configuration_changed,
       "OAuth provider configuration changed"
     )}
  end

  defp provider_opts(opts), do: Keyword.get(opts, :provider_opts, [])

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

  defp send_method_view(method) do
    %View.SendMethod{
      id: method.id,
      account_id: method.account_id,
      kind: method.kind,
      email_address: method.email_address,
      status: method.status,
      enabled: method.enabled,
      last_verified_at: method.last_verified_at,
      last_error: method.last_error_message
    }
  end

  defp submission_method(method, opts \\ []) do
    %SubmissionMethod{
      id: method.id,
      account_id: method.account_id,
      kind: method.kind,
      email_address: method.email_address,
      credential: Keyword.get(opts, :credential),
      config: Keyword.get(opts, :config)
    }
  end

  defp normalize_folder_kind(folder_kind) when folder_kind in ~w(inbox archive sent trash),
    do: folder_kind

  defp normalize_folder_kind(_folder_kind), do: "archive"

  defp credential_context(account_id, kind), do: "credential:#{account_id}:#{kind}"

  defp imap_transport do
    Application.get_env(:manifold_connectors, :imap_transport, Client)
  end

  defp smtp_transport do
    Application.get_env(:manifold_connectors, :smtp_transport, SmtpClient)
  end

  defp eas_transport do
    Application.get_env(:manifold_connectors, :eas_transport, EASClient)
  end

  defp discover_eas(settings) when is_map(settings) do
    case do_discover_eas(settings) do
      {:ok, _} = ok ->
        ok

      {:error, error} = first ->
        if EASClient.gateway_html_400_error?(error) do
          discover_eas_with_fallbacks(settings, error)
        else
          first
        end
    end
  end

  defp discover_eas_with_fallbacks(settings, original_error) do
    # Re-run full connect/provision/FolderSync with QQ-friendly shapes.
    # Version-only FolderSync retries are not enough after a bad Provision.
    strategies = [
      %{force_protocol_version: "14.0", prefer_base64_query: false, force_query_mode: :plain},
      %{
        force_protocol_version: "14.0",
        prefer_base64_query: false,
        force_query_mode: :plain,
        skip_provision: true
      },
      %{force_protocol_version: "14.0", prefer_base64_query: true, force_query_mode: :base64},
      %{
        force_protocol_version: "14.0",
        prefer_base64_query: true,
        force_query_mode: :base64,
        skip_provision: true
      },
      %{force_protocol_version: "12.1", prefer_base64_query: false, force_query_mode: :plain},
      %{
        force_protocol_version: "12.1",
        prefer_base64_query: false,
        force_query_mode: :plain,
        skip_provision: true
      }
    ]

    Enum.reduce_while(strategies, {:error, original_error}, fn strategy, acc ->
      case do_discover_eas(Map.merge(settings, strategy)) do
        {:ok, result} -> {:halt, {:ok, result}}
        {:error, _} -> {:cont, acc}
      end
    end)
  end

  defp do_discover_eas(settings) when is_map(settings) do
    transport = eas_transport()
    skip_provision? = Map.get(settings, :skip_provision) == true

    with {:ok, conn} <- transport.connect(settings),
         {:ok, conn, policy_key} <- discover_eas_provision(transport, conn, skip_provision?),
         {:ok, conn, %{sync_key: folder_sync_key, folders: folders}} <-
           discover_eas_folder_sync(transport, conn, skip_provision?) do
      collection_id = EASClient.inbox_collection_id(folders)
      transport.close(conn)

      if is_binary(collection_id) do
        {:ok,
         %{
           policy_key: policy_key,
           folder_sync_key: folder_sync_key,
           collection_id: collection_id,
           device_id: settings.device_id,
           protocol_version:
             Map.get(settings, :force_protocol_version) || settings.protocol_version
         }}
      else
        {:error,
         %ProviderError{
           class: :permanent,
           code: :inbox_not_found,
           message: "EAS Inbox folder was not found"
         }}
      end
    else
      {:error, %ProviderError{} = error} -> {:error, error}
    end
  end

  defp discover_eas_provision(transport, conn, false) do
    case transport.provision(conn) do
      {:ok, conn, %{policy_key: policy_key}} -> {:ok, conn, policy_key}
      {:error, _} = error -> error
    end
  end

  defp discover_eas_provision(_transport, conn, true) do
    policy_key =
      case conn do
        %{policy_key: key} when is_binary(key) and key != "" -> key
        _ -> "0"
      end

    {:ok, conn, policy_key}
  end

  defp discover_eas_folder_sync(transport, conn, skip_provision?) do
    case transport.folder_sync(conn, "0") do
      {:ok, _, _} = ok ->
        ok

      {:error, %ProviderError{code: :provision_required}} when skip_provision? ->
        with {:ok, conn, _} <- transport.provision(conn) do
          transport.folder_sync(conn, "0")
        end

      {:error, _} = error ->
        error
    end
  end

  defp reject_duplicate_eas(email_canonical, provider_account_id) do
    conflict =
      ReceiveMethod
      |> where([account], account.status != "disconnected")
      |> where(
        [account],
        account.provider_account_id == ^provider_account_id or
          (account.kind == "eas" and
             fragment("lower(?) = ?", account.email_address, ^email_canonical))
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
           "an EAS account for this address is already connected"
         )}
    end
  end

  defp eas_settings_from_attrs(attrs) do
    host = attr(attrs, :host)
    username = attr(attrs, :username) || attr(attrs, :email_address)
    domain = blank_to_nil(attr(attrs, :domain))
    password = attr(attrs, :password)
    path = attr(attrs, :path) || EasSettings.default_path()
    port = parse_port(attr(attrs, :port) || 443)
    device_id = attr(attrs, :device_id) || generate_eas_device_id()
    device_type = attr(attrs, :device_type) || EasSettings.default_device_type()
    protocol_version = attr(attrs, :protocol_version) || EasSettings.default_protocol_version()

    cond do
      not is_binary(host) or host == "" ->
        {:error, Error.new(:permanent, :invalid_eas_settings, "EAS host is required")}

      not is_binary(username) or username == "" ->
        {:error, Error.new(:permanent, :invalid_eas_settings, "EAS username is required")}

      not is_binary(password) or password == "" ->
        {:error, Error.new(:permanent, :invalid_eas_settings, "EAS password is required")}

      not is_integer(port) ->
        {:error, Error.new(:permanent, :invalid_eas_settings, "EAS port is invalid")}

      true ->
        settings = %{
          host: host,
          port: port,
          path: path,
          domain: domain,
          username: username,
          password: password,
          device_id: device_id,
          device_type: device_type,
          protocol_version: protocol_version,
          policy_key: attr(attrs, :policy_key)
        }

        fake = Application.get_env(:manifold_connectors, :eas_fake, %{})

        {:ok,
         settings
         |> Map.merge(if(is_map(fake), do: fake, else: %{}))
         |> maybe_merge_attr_fake(attrs)}
    end
  end

  defp normalize_eas_attrs(attrs) when is_map(attrs) do
    attrs
    |> maybe_put_trimmed(:host)
    |> maybe_put_trimmed(:username)
    |> maybe_put_trimmed(:email_address)
    |> maybe_put_trimmed(:path)
    |> maybe_put_trimmed(:domain)
    |> maybe_put_password_without_spaces()
    |> maybe_put_normalized_port()
    |> maybe_put_device_id()
  end

  defp maybe_put_device_id(attrs) do
    case attr(attrs, :device_id) do
      value when is_binary(value) and value != "" ->
        put_attr(attrs, :device_id, String.slice(String.trim(value), 0, 32))

      _ ->
        put_attr(attrs, :device_id, generate_eas_device_id())
    end
  end

  defp generate_eas_device_id do
    # MS-ASHTTP device IDs are typically 32 hex chars. Fake "Appl…" prefixes
    # do not help against gateways that fingerprint TLS/UA (e.g. QQ Exmail).
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end

  defp eas_provider_config(attrs, discovered) do
    [
      host: attr(attrs, :host),
      port: parse_port(attr(attrs, :port) || 443),
      path: attr(attrs, :path) || EasSettings.default_path(),
      domain: blank_to_nil(attr(attrs, :domain)),
      username: attr(attrs, :username) || attr(attrs, :email_address),
      email_address: attr(attrs, :email_address),
      device_id: attr(attrs, :device_id) || discovered.device_id,
      device_type: attr(attrs, :device_type) || EasSettings.default_device_type(),
      protocol_version:
        Map.get(discovered, :protocol_version) || attr(attrs, :protocol_version) ||
          EasSettings.default_protocol_version(),
      policy_key: discovered.policy_key,
      collection_id: discovered.collection_id,
      folder_sync_key: discovered.folder_sync_key,
      transport: eas_transport()
    ]
  end

  defp persist_eas_account(attrs, parsed, provider_account_id, mailbox, cursors, discovered, now) do
    password = attr(attrs, :password)
    username = attr(attrs, :username) || parsed.canonical
    domain = blank_to_nil(attr(attrs, :domain))
    host = attr(attrs, :host)
    port = parse_port(attr(attrs, :port) || 443)
    path = attr(attrs, :path) || EasSettings.default_path()
    device_id = attr(attrs, :device_id) || discovered.device_id
    device_type = attr(attrs, :device_type) || EasSettings.default_device_type()

    protocol_version =
      Map.get(discovered, :protocol_version) || attr(attrs, :protocol_version) ||
        EasSettings.default_protocol_version()

    Multi.new()
    |> Multi.run(:mailbox_fence, fn repo, _changes ->
      ensure_active_mailbox(repo, mailbox.id)
    end)
    |> Multi.run(:disable_others, fn repo, _changes ->
      disable_other_methods(repo, mailbox.id)
      {:ok, :ok}
    end)
    |> Multi.insert(:account, fn _changes ->
      ReceiveMethod.changeset(%ReceiveMethod{}, %{
        account_id: mailbox.id,
        kind: "eas",
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
             Crypto.encrypt(password, credential_context(account.id, :eas_password)) do
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
    |> Multi.insert(:eas_settings, fn %{account: account} ->
      EasSettings.changeset(%EasSettings{}, %{
        external_account_id: account.id,
        host: host,
        port: port,
        path: path,
        domain: domain,
        username: username,
        device_id: device_id,
        device_type: device_type,
        protocol_version: protocol_version,
        policy_key: discovered.policy_key
      })
    end)
    |> Multi.run(:cursors, fn repo, %{account: account} ->
      replace_cursors(repo, account.id, cursors, now)
    end)
    |> Multi.insert(:event, fn %{account: account} ->
      ConnectorEvent.changeset(%ConnectorEvent{}, %{
        external_account_id: account.id,
        event_type: "connected",
        metadata: %{provider: "eas"},
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
    tls_mode = attr(attrs, :tls_mode) || "tls"
    mailbox_path = attr(attrs, :mailbox_path) || "INBOX"
    port = parse_port(attr(attrs, :port) || 993)

    cond do
      not is_binary(host) or host == "" ->
        {:error, Error.new(:permanent, :invalid_imap_settings, "IMAP host is required")}

      not is_binary(username) or username == "" ->
        {:error, Error.new(:permanent, :invalid_imap_settings, "IMAP username is required")}

      not is_binary(password) or password == "" ->
        {:error, Error.new(:permanent, :invalid_imap_settings, "IMAP password is required")}

      tls_mode not in ["ssl", "tls", "starttls"] ->
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
    |> maybe_put_password_without_spaces()
    |> maybe_put_normalized_port()
  end

  defp maybe_put_trimmed(attrs, key) do
    case attr(attrs, key) do
      value when is_binary(value) -> put_attr(attrs, key, String.trim(value))
      _ -> attrs
    end
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_), do: nil

  defp maybe_put_password_without_spaces(attrs) do
    case attr(attrs, :password) do
      value when is_binary(value) ->
        put_attr(attrs, :password, value |> String.trim() |> String.replace(" ", ""))

      _ ->
        attrs
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
      tls_mode: attr(attrs, :tls_mode) || "tls",
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
    tls_mode = attr(attrs, :tls_mode) || "tls"
    mailbox_path = attr(attrs, :mailbox_path) || "INBOX"

    Multi.new()
    |> Multi.run(:mailbox_fence, fn repo, _changes ->
      ensure_active_mailbox(repo, mailbox.id)
    end)
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

  defp resolve_send_account(account_id) when is_binary(account_id) do
    case Accounts.get_account(account_id) do
      nil -> {:error, Error.new(:permanent, :account_not_found, "account not found")}
      account -> {:ok, account}
    end
  end

  defp resolve_send_account(_) do
    {:error, Error.new(:permanent, :account_not_found, "account not found")}
  end

  defp lock_send_method(method_id) do
    SendMethod
    |> where([method], method.id == ^method_id)
    |> lock("FOR UPDATE")
    |> Repo.one()
    |> case do
      %SendMethod{} = method -> {:ok, method}
      nil -> {:error, send_method_required()}
    end
  end

  defp preflight_send_method(method_id, required_sender) do
    case Repo.get(SendMethod, method_id) do
      %SendMethod{} = method ->
        case validate_send_method_checkout(method, required_sender) do
          :ok -> {:ok, method}
          {:error, _reason} = error -> error
        end

      nil ->
        {:error, send_method_required()}
    end
  end

  defp validate_send_method_checkout(
         %SendMethod{status: "disconnected"},
         _required_sender
       ) do
    {:error, Error.new(:permanent, :account_disconnected, "send method is disconnected")}
  end

  defp validate_send_method_checkout(
         %SendMethod{status: "reconnect_required"},
         _required_sender
       ) do
    {:error,
     Error.new(:permanent, :reauthorization_required, "send method requires reauthorization")}
  end

  defp validate_send_method_checkout(%SendMethod{enabled: false}, _required_sender),
    do: {:error, send_method_required()}

  defp validate_send_method_checkout(
         %SendMethod{status: "connected"} = method,
         required_sender
       ) do
    with %{} = account <- Accounts.get_account(method.account_id),
         {:ok, method_sender} <- Address.parse(method.email_address),
         {:ok, account_sender} <- Address.parse(Accounts.account_address(account)),
         true <-
           required_sender.canonical == method_sender.canonical and
             method_sender.canonical == account_sender.canonical do
      :ok
    else
      nil -> {:error, send_method_required()}
      _mismatch -> {:error, sender_address_mismatch()}
    end
  end

  defp validate_send_method_checkout(%SendMethod{}, _required_sender),
    do: {:error, send_method_required()}

  defp checkout_oauth_send_method(
         %SendMethod{kind: provider, oauth_authorization_id: authorization_id} = snapshot,
         required_sender,
         opts
       )
       when provider in ["gmail", "microsoft"] and is_binary(authorization_id) do
    with {:ok, adapter, provider_config} <- adapter_config(provider),
         {:ok, config} <- oauth_submission_config(provider, provider_config),
         {:ok, required_scope} <- OAuthScopes.method_scope(provider, :send) do
      continuation = fn access_token ->
        with :ok <- after_oauth_checkout(opts) do
          lock_and_revalidate_oauth_method(
            snapshot,
            required_sender,
            access_token,
            config
          )
        end
      end

      checkout_resolved_oauth_access_token(
        authorization_id,
        provider,
        adapter,
        provider_config,
        opts
        |> Keyword.delete(:after_oauth_checkout)
        |> Keyword.put(:required_scope, required_scope)
        |> Keyword.put(:access_token_continuation, continuation)
      )
    end
  end

  defp checkout_oauth_send_method(
         %SendMethod{kind: provider},
         _required_sender,
         _opts
       )
       when provider in ["gmail", "microsoft"],
       do: {:error, send_method_required()}

  defp lock_and_revalidate_oauth_method(
         snapshot,
         required_sender,
         access_token,
         config
       ) do
    with {:ok, method} <- lock_send_method(snapshot.id),
         :ok <- validate_send_method_checkout(method, required_sender),
         :ok <- validate_oauth_method_snapshot(method, snapshot) do
      {:ok, submission_method(method, credential: {:oauth, access_token}, config: config)}
    end
  end

  defp checkout_smtp_send_method(snapshot, required_sender) do
    Repo.transaction(fn ->
      with {:ok, method} <- lock_send_method(snapshot.id),
           :ok <- validate_send_method_checkout(method, required_sender),
           :ok <- validate_smtp_method_snapshot(method, snapshot),
           {:ok, credential, config} <- checkout_smtp_credential(method) do
        submission_method(method, credential: credential, config: config)
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, %SubmissionMethod{} = method} -> {:ok, method}
      {:error, reason} -> {:error, reason}
    end
  end

  defp checkout_smtp_credential(%SendMethod{kind: "smtp"} = method) do
    with %SendCredential{} = credential <-
           Repo.get_by(SendCredential, send_method_id: method.id),
         %SmtpSettings{} = settings <- Repo.get_by(SmtpSettings, send_method_id: method.id),
         {:ok, password} <-
           Crypto.decrypt(
             credential.password_ciphertext,
             credential_context(method.id, :smtp_password)
           ) do
      config = Map.take(settings, [:host, :port, :tls_mode, :username])
      {:ok, {:password, password}, config}
    else
      nil -> {:error, send_method_required()}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_oauth_method_snapshot(
         %SendMethod{} = method,
         %SendMethod{} = snapshot
       ) do
    if method.id == snapshot.id and
         method.kind in ["gmail", "microsoft"] and
         method.kind == snapshot.kind and
         method.oauth_authorization_id == snapshot.oauth_authorization_id and
         method.account_id == snapshot.account_id and
         method.email_address == snapshot.email_address and
         method.status == snapshot.status and
         method.enabled == snapshot.enabled and
         method.lock_version == snapshot.lock_version do
      :ok
    else
      {:error, send_method_required()}
    end
  end

  defp validate_smtp_method_snapshot(method, snapshot) do
    if method.kind == "smtp" and method.account_id == snapshot.account_id and
         method.email_address == snapshot.email_address do
      :ok
    else
      {:error, send_method_required()}
    end
  end

  defp after_oauth_checkout(opts) do
    case Keyword.get(opts, :after_oauth_checkout) do
      callback when is_function(callback, 0) ->
        callback.()
        :ok

      nil ->
        :ok
    end
  end

  defp oauth_submission_config(provider, config)
       when provider in ["gmail", "microsoft"] and is_list(config) do
    case Keyword.get(config, :base_url) do
      base_url when is_binary(base_url) and base_url != "" ->
        safe_req_options =
          config
          |> Keyword.get(:req_options, [])
          |> Keyword.take([:plug])

        submission_config = [base_url: base_url]

        if safe_req_options == [] do
          {:ok, submission_config}
        else
          {:ok, Keyword.put(submission_config, :req_options, safe_req_options)}
        end

      _missing ->
        provider_not_configured()
    end
  end

  defp oauth_authorization_provider(authorization_id) do
    with {:ok, authorization_id} <- Ecto.UUID.cast(authorization_id),
         provider when is_binary(provider) <-
           OAuthAuthorization
           |> where([authorization], authorization.id == ^authorization_id)
           |> select([authorization], authorization.provider)
           |> Repo.one() do
      if provider in ["gmail", "microsoft"] do
        {:ok, authorization_id, provider}
      else
        invalid_oauth_authorization()
      end
    else
      :error -> authorization_not_found()
      nil -> authorization_not_found()
    end
  end

  defp authorization_not_found do
    {:error, Error.new(:permanent, :authorization_not_found, "authorization not found")}
  end

  defp invalid_oauth_authorization do
    {:error,
     Error.new(
       :permanent,
       :invalid_oauth_authorization,
       "authorization is not a supported OAuth authorization"
     )}
  end

  defp provider_not_configured do
    {:error, Error.new(:permanent, :provider_not_configured, "provider is not configured")}
  end

  defp require_account_sender(parsed, account) do
    with {:ok, account_address} <- Address.parse(Accounts.account_address(account)),
         true <- parsed.canonical == account_address.canonical do
      :ok
    else
      _mismatch -> {:error, sender_address_mismatch()}
    end
  end

  defp send_method_required do
    Error.new(:permanent, :send_method_required, "an enabled send method is required")
  end

  defp sender_address_mismatch do
    Error.new(
      :permanent,
      :sender_address_mismatch,
      "send method address does not match the account sender"
    )
  end

  defp maybe_test_smtp(_attrs, true), do: :ok

  defp maybe_test_smtp(attrs, false) do
    case test_smtp_connection(attrs) do
      :ok -> :ok
      {:error, %ProviderError{} = error} -> {:error, error}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp disable_other_send_methods(repo, account_id, opts \\ []) do
    except_id = Keyword.get(opts, :except_id)

    query =
      SendMethod
      |> where([m], m.account_id == ^account_id and m.enabled == true)

    query =
      if except_id do
        where(query, [m], m.id != ^except_id)
      else
        query
      end

    repo.update_all(query, set: [enabled: false, updated_at: DateTime.utc_now()])
  end

  defp smtp_settings_from_attrs(attrs) do
    host = attr(attrs, :host)
    username = attr(attrs, :username) || attr(attrs, :email_address)
    password = attr(attrs, :password)
    tls_mode = attr(attrs, :tls_mode) || "tls"
    port = parse_port(attr(attrs, :port) || 465)

    cond do
      not is_binary(host) or host == "" ->
        {:error, Error.new(:permanent, :invalid_smtp_settings, "SMTP host is required")}

      not is_binary(username) or username == "" ->
        {:error, Error.new(:permanent, :invalid_smtp_settings, "SMTP username is required")}

      not is_binary(password) or password == "" ->
        {:error, Error.new(:permanent, :invalid_smtp_settings, "SMTP password is required")}

      tls_mode not in ["ssl", "tls", "starttls"] ->
        {:error, Error.new(:permanent, :invalid_smtp_settings, "SMTP tls_mode is invalid")}

      not is_integer(port) ->
        {:error, Error.new(:permanent, :invalid_smtp_settings, "SMTP port is invalid")}

      true ->
        settings = %{
          host: host,
          port: port,
          tls_mode: tls_mode,
          username: username,
          password: password
        }

        fake = Application.get_env(:manifold_connectors, :smtp_fake, %{})

        {:ok,
         settings
         |> Map.merge(if(is_map(fake), do: fake, else: %{}))
         |> maybe_merge_attr_fake(attrs)}
    end
  end

  defp normalize_smtp_attrs(attrs) when is_map(attrs) do
    attrs
    |> maybe_put_trimmed(:host)
    |> maybe_put_trimmed(:username)
    |> maybe_put_trimmed(:email_address)
    |> maybe_put_password_without_spaces()
    |> maybe_put_normalized_port()
  end

  defp persist_smtp_send_method(attrs, parsed, mailbox, now) do
    password = attr(attrs, :password)
    username = attr(attrs, :username) || parsed.canonical
    host = attr(attrs, :host)
    port = parse_port(attr(attrs, :port) || 465)
    tls_mode = attr(attrs, :tls_mode) || "tls"

    Multi.new()
    |> Multi.run(:mailbox_fence, fn repo, _changes ->
      ensure_active_mailbox(repo, mailbox.id)
    end)
    |> Multi.run(:disable_others, fn repo, _changes ->
      disable_other_send_methods(repo, mailbox.id)
      {:ok, :ok}
    end)
    |> Multi.insert(:method, fn _changes ->
      SendMethod.changeset(%SendMethod{}, %{
        account_id: mailbox.id,
        kind: "smtp",
        email_address: parsed.canonical,
        status: "connected",
        enabled: true,
        last_verified_at: now
      })
    end)
    |> Multi.run(:credential, fn repo, %{method: method} ->
      with {:ok, ciphertext} <-
             Crypto.encrypt(password, credential_context(method.id, :smtp_password)) do
        SendCredential.changeset(%SendCredential{}, %{
          send_method_id: method.id,
          key_version: 1,
          password_ciphertext: ciphertext
        })
        |> repo.insert()
      end
    end)
    |> Multi.insert(:smtp_settings, fn %{method: method} ->
      SmtpSettings.changeset(%SmtpSettings{}, %{
        send_method_id: method.id,
        host: host,
        port: port,
        tls_mode: tls_mode,
        username: username
      })
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{method: method}} -> {:ok, method}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  defp ensure_active_mailbox(repo, mailbox_id) do
    Accounts.active_account_for_update(repo, mailbox_id)
  end

  defp lock_receive_method(repo, receive_method_id) do
    ReceiveMethod
    |> where([method], method.id == ^receive_method_id)
    |> lock("FOR UPDATE")
    |> repo.one()
  end

  defp lock_send_method(repo, send_method_id) do
    SendMethod
    |> where([method], method.id == ^send_method_id)
    |> lock("FOR UPDATE")
    |> repo.one()
  end

  defp enable_receive_method(repo, %ReceiveMethod{status: "disconnected"}) do
    repo.rollback(Error.new(:permanent, :account_disconnected, "receive method is disconnected"))
  end

  defp enable_receive_method(repo, %ReceiveMethod{status: "not_implemented"}) do
    repo.rollback(
      Error.new(:permanent, :not_implemented, "receive method is not implemented yet")
    )
  end

  defp enable_receive_method(repo, %ReceiveMethod{status: "reconnect_required"}) do
    repo.rollback(
      Error.new(
        :permanent,
        :reauthorization_required,
        "receive method requires reauthorization"
      )
    )
  end

  defp enable_receive_method(repo, %ReceiveMethod{} = method) do
    disable_other_methods(repo, method.account_id, except_id: method.id)

    case ReceiveMethod.changeset(method, %{enabled: true, sync_enabled: true}) |> repo.update() do
      {:ok, updated} -> updated
      {:error, changeset} -> repo.rollback(changeset)
    end
  end

  defp enable_locked_send_method(repo, %SendMethod{status: "disconnected"}) do
    repo.rollback(Error.new(:permanent, :account_disconnected, "send method is disconnected"))
  end

  defp enable_locked_send_method(repo, %SendMethod{status: "reconnect_required"}) do
    repo.rollback(
      Error.new(
        :permanent,
        :reauthorization_required,
        "send method requires reauthorization"
      )
    )
  end

  defp enable_locked_send_method(repo, %SendMethod{} = method) do
    disable_other_send_methods(repo, method.account_id, except_id: method.id)

    case SendMethod.changeset(method, %{enabled: true}) |> repo.update() do
      {:ok, updated} -> updated
      {:error, changeset} -> repo.rollback(changeset)
    end
  end

  defp enqueue_sync(repo, %ReceiveMethod{status: "disconnected"}) do
    repo.rollback(Error.new(:permanent, :account_disconnected, "receive method is disconnected"))
  end

  defp enqueue_sync(repo, %ReceiveMethod{enabled: false}) do
    repo.rollback(Error.new(:permanent, :sync_disabled, "receive method is not enabled"))
  end

  defp enqueue_sync(repo, %ReceiveMethod{sync_enabled: true} = account) do
    ensure_sync_job(repo, account.id)
  end

  defp enqueue_sync(repo, %ReceiveMethod{}) do
    repo.rollback(Error.new(:permanent, :sync_disabled, "connector synchronization is disabled"))
  end

  defp account_job_query(mailbox_id) do
    Oban.Job
    |> where([job], job.state in ~w(available scheduled executing retryable suspended cancelled))
    |> where(
      [job],
      (job.worker == ^inspect(SyncAccount) and
         fragment(
           """
           EXISTS (
             SELECT 1
             FROM connector_accounts AS receive_method
             WHERE receive_method.mailbox_id = ?
               AND receive_method.id = CASE
                 WHEN (?->>'external_account_id') ~*
                   '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
                 THEN (?->>'external_account_id')::uuid
                 ELSE NULL
               END
           )
           """,
           type(^mailbox_id, :binary_id),
           job.args,
           job.args
         )) or
        (job.worker in ^[inspect(ApplyRemoteState), inspect(PushRemoteRead)] and
           fragment(
             """
             EXISTS (
               SELECT 1
               FROM connector_remote_messages AS remote_message
               INNER JOIN connector_accounts AS receive_method
                 ON receive_method.id = remote_message.external_account_id
               WHERE receive_method.mailbox_id = ?
                 AND remote_message.id = CASE
                   WHEN (?->>'remote_message_id') ~*
                     '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
                   THEN (?->>'remote_message_id')::uuid
                   ELSE NULL
                 END
             )
             """,
             type(^mailbox_id, :binary_id),
             job.args,
             job.args
           ))
    )
  end

  defp delete_account_jobs(_repo, []), do: 0

  defp delete_account_jobs(repo, ids) do
    {count, _rows} =
      Oban.Job
      |> where([job], job.id in ^ids)
      |> repo.delete_all()

    count
  end

  defp cancel_executing_account_jobs([]), do: 0

  defp cancel_executing_account_jobs(ids) do
    {:ok, count} =
      Oban.Job
      |> where([job], job.id in ^ids and job.state == "executing")
      |> Oban.cancel_all_jobs()

    count
  end

  defp due_mailbox_ids(repo) do
    ReceiveMethod
    |> join(:inner, [method], mailbox in Account, on: mailbox.id == method.account_id)
    |> due_receive_methods()
    |> distinct([_method, mailbox], mailbox.id)
    |> order_by([_method, mailbox], asc: mailbox.id)
    |> select([_method, mailbox], mailbox.id)
    |> repo.all()
  end

  defp due_receive_method_ids(_repo, []), do: []

  defp due_receive_method_ids(repo, mailbox_ids) do
    ReceiveMethod
    |> join(:inner, [method], mailbox in Account, on: mailbox.id == method.account_id)
    |> due_receive_methods()
    |> where([_method, mailbox], mailbox.id in ^mailbox_ids)
    |> order_by([method, _mailbox], asc: method.id)
    |> select([method, _mailbox], method.id)
    |> repo.all()
  end

  defp due_receive_methods(query) do
    where(
      query,
      [method, mailbox],
      method.enabled and method.sync_enabled and
        method.status in ["connected", "syncing", "failed"] and
        method.kind in ^ReceiveMethod.implemented_kinds() and mailbox.active and
        is_nil(mailbox.purge_requested_at)
    )
  end

  defp maybe_before_locked_recheck(opts) do
    case Keyword.get(opts, :before_locked_recheck) do
      callback when is_function(callback, 0) -> callback.()
      nil -> :ok
    end
  end

  defp lock_active_mailboxes(repo, mailbox_ids, inactive_mode) do
    mailbox_ids
    |> Enum.reduce([], fn mailbox_id, active_ids ->
      case ensure_active_mailbox(repo, mailbox_id) do
        {:ok, _mailbox} ->
          [mailbox_id | active_ids]

        {:error, %Error{reason: :mailbox_not_active} = error} ->
          case inactive_mode do
            :skip_inactive -> active_ids
            :rollback_on_inactive -> repo.rollback(error)
          end

        {:error, reason} ->
          repo.rollback(reason)
      end
    end)
    |> Enum.reverse()
  end

  defp read_push_query(entry_ids) do
    from(entry in MailboxEntry,
      join: remote in RemoteMessage,
      on: remote.inbound_delivery_id == entry.inbound_delivery_id,
      join: method in ReceiveMethod,
      on: method.id == remote.external_account_id and method.account_id == entry.mailbox_id,
      where:
        entry.id in ^entry_ids and method.kind in ["imap", "eas"] and
          method.status != "disconnected"
    )
  end

  defp read_push_mailbox_ids(repo, entry_ids) do
    entry_ids
    |> read_push_query()
    |> distinct([_entry, _remote, method], method.account_id)
    |> order_by([_entry, _remote, method], asc: method.account_id)
    |> select([_entry, _remote, method], method.account_id)
    |> repo.all()
  end

  defp read_push_remote_ids(entry_ids, repo, mailbox_ids) do
    entry_ids
    |> read_push_query()
    |> where([_entry, _remote, method], method.account_id in ^mailbox_ids)
    |> distinct([_entry, remote, _method], remote.id)
    |> order_by([_entry, remote, _method], asc: remote.id)
    |> select([_entry, remote, _method], remote.id)
    |> repo.all()
  end

  defp lock_remote_messages([], _repo), do: []

  defp lock_remote_messages(remote_ids, repo) do
    RemoteMessage
    |> where([remote], remote.id in ^remote_ids)
    |> order_by([remote], asc: remote.id)
    |> lock("FOR UPDATE")
    |> repo.all()
  end

  defp next_purge_batch(repo, mailbox_id, limit) do
    remote_ids =
      RemoteMessage
      |> join(:inner, [remote], method in ReceiveMethod,
        on: method.id == remote.external_account_id
      )
      |> where([_remote, method], method.account_id == ^mailbox_id)
      |> order_by([remote, _method], asc: remote.id)
      |> limit(^limit)
      |> lock("FOR UPDATE")
      |> select([remote, _method], remote.id)
      |> repo.all()

    cond do
      remote_ids != [] ->
        {:remote_messages, remote_ids}

      receive_ids = purge_ids(repo, ReceiveMethod, :account_id, mailbox_id, limit) ->
        {:receive_methods, receive_ids}

      send_ids = purge_ids(repo, SendMethod, :account_id, mailbox_id, limit) ->
        {:send_methods, send_ids}

      oauth_ids = purge_ids(repo, OAuthTransaction, :mailbox_id, mailbox_id, limit) ->
        {:oauth_transactions, oauth_ids}

      true ->
        :empty
    end
  end

  defp purge_ids(repo, schema, field, mailbox_id, limit) do
    ids =
      schema
      |> where([row], field(row, ^field) == ^mailbox_id)
      |> order_by([row], asc: row.id)
      |> limit(^limit)
      |> lock("FOR UPDATE")
      |> select([row], row.id)
      |> repo.all()

    if ids == [], do: nil, else: ids
  end

  defp purge_result(repo, mailbox_id, deleted, activity_log_ids) do
    %{
      deleted: deleted,
      done?: not account_data_remaining?(repo, mailbox_id),
      activity_log_ids: activity_log_ids
    }
  end

  defp account_data_remaining?(repo, mailbox_id) do
    repo.exists?(where(ReceiveMethod, [method], method.account_id == ^mailbox_id)) or
      repo.exists?(where(SendMethod, [method], method.account_id == ^mailbox_id)) or
      repo.exists?(where(OAuthTransaction, [transaction], transaction.mailbox_id == ^mailbox_id))
  end

  defp database_error(reason) do
    Error.new(:temporary, :database_unavailable, "connector database operation failed", %{
      reason: inspect(reason)
    })
  end
end
