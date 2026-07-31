defmodule Manifold.Connectors.OAuth do
  @moduledoc """
  One-time OAuth authorization transactions.

  Microsoft uses the Device Authorization Grant. Gmail keeps authorization code
  plus PKCE because Google's device-flow allowlist excludes Gmail API scopes.
  """

  import Ecto.Query

  alias Manifold.Connectors.Crypto
  alias Manifold.Connectors.Provider.Error, as: ProviderError
  alias Manifold.Connectors.Provider.Token
  alias Manifold.Connectors.Schema.OAuthTransaction
  alias Manifold.Core.Error
  alias Manifold.Repo

  @providers ~w(gmail microsoft)
  @default_ttl_seconds 600

  defmodule Authorization do
    @moduledoc false
    @enforce_keys [:url, :state]
    defstruct @enforce_keys

    @type t :: %__MODULE__{url: String.t(), state: String.t()}
  end

  defmodule Consumed do
    @moduledoc false
    @enforce_keys [:provider, :mailbox_id, :redirect_uri, :pkce_verifier]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            provider: String.t(),
            mailbox_id: Ecto.UUID.t(),
            redirect_uri: String.t(),
            pkce_verifier: String.t()
          }
  end

  defmodule DeviceAuthorization do
    @moduledoc false
    @enforce_keys [:state, :user_code, :verification_uri, :interval_seconds, :expires_at]
    defstruct [:verification_uri_complete | @enforce_keys]

    @type t :: %__MODULE__{
            state: String.t(),
            user_code: String.t(),
            verification_uri: String.t(),
            verification_uri_complete: String.t() | nil,
            interval_seconds: pos_integer(),
            expires_at: DateTime.t()
          }
  end

  defmodule DeviceConsumed do
    @moduledoc false
    @enforce_keys [:provider, :mailbox_id]
    defstruct @enforce_keys

    @type t :: %__MODULE__{provider: String.t(), mailbox_id: Ecto.UUID.t()}
  end

  @spec start(String.t(), Ecto.UUID.t(), String.t(), Keyword.t()) ::
          {:ok, Authorization.t()} | {:error, Error.t() | Ecto.Changeset.t()}
  def start(provider, mailbox_id, redirect_uri, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    ttl_seconds = Keyword.get(opts, :ttl_seconds, @default_ttl_seconds)

    with :ok <- require_authorization_code_provider(provider),
         {:ok, config} <- provider_config(provider),
         :ok <- validate_redirect_uri(redirect_uri),
         true <- is_integer(ttl_seconds) and ttl_seconds > 0,
         state = random_url_token(),
         verifier = random_url_token(),
         {:ok, encrypted_verifier} <-
           Crypto.encrypt(verifier, verifier_context(provider, mailbox_id)) do
      attrs = %{
        state_digest: state_digest(state),
        provider: provider,
        mailbox_id: mailbox_id,
        flow: "authorization_code",
        pkce_verifier_ciphertext: encrypted_verifier,
        redirect_uri: redirect_uri,
        expires_at: DateTime.add(now, ttl_seconds, :second)
      }

      case OAuthTransaction.changeset(%OAuthTransaction{}, attrs) |> Repo.insert() do
        {:ok, _transaction} ->
          {:ok,
           %Authorization{
             url: authorization_url(provider, config, redirect_uri, state, verifier),
             state: state
           }}

        {:error, changeset} ->
          {:error, changeset}
      end
    else
      false ->
        {:error,
         Error.new(:permanent, :invalid_oauth_ttl, "OAuth state lifetime must be positive")}

      {:error, %Error{} = error} ->
        {:error, error}
    end
  rescue
    DBConnection.ConnectionError ->
      {:error, Error.new(:temporary, :database_unavailable, "OAuth database is unavailable")}
  end

  @spec consume(String.t(), String.t(), String.t(), Keyword.t()) ::
          {:ok, Consumed.t()} | {:error, Error.t()}
  def consume(provider, state, redirect_uri, opts \\ [])
      when is_binary(state) and is_binary(redirect_uri) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    Repo.transaction(fn ->
      transaction =
        OAuthTransaction
        |> where([transaction], transaction.state_digest == ^state_digest(state))
        |> lock("FOR UPDATE")
        |> Repo.one()

      consume_authorization_code(transaction, provider, redirect_uri, now)
    end)
    |> case do
      {:ok, {:ok, %Consumed{} = consumed}} -> {:ok, consumed}
      {:ok, {:error, %Error{} = error}} -> {:error, error}
      {:error, %Error{} = error} -> {:error, error}
      {:error, reason} -> {:error, database_error(reason)}
    end
  rescue
    DBConnection.ConnectionError ->
      {:error, database_error(:unavailable)}
  end

  @spec start_device(String.t(), Ecto.UUID.t(), Keyword.t()) ::
          {:ok, DeviceAuthorization.t()} | {:error, Error.t() | Ecto.Changeset.t()}
  def start_device(provider, mailbox_id, opts \\ []) do
    with :ok <- require_device_provider(provider),
         {:ok, adapter, config} <- adapter_config(provider),
         {:ok, device} <- adapter.request_device_code(config, provider_opts(opts)),
         state = random_url_token(),
         {:ok, encrypted_device_code} <-
           Crypto.encrypt(device.device_code, device_context(provider, mailbox_id)) do
      attrs = %{
        state_digest: state_digest(state),
        provider: provider,
        mailbox_id: mailbox_id,
        flow: "device",
        device_code_ciphertext: encrypted_device_code,
        user_code: device.user_code,
        verification_uri: device.verification_uri,
        verification_uri_complete: device.verification_uri_complete,
        interval_seconds: device.interval_seconds,
        expires_at: device.expires_at
      }

      case OAuthTransaction.changeset(%OAuthTransaction{}, attrs) |> Repo.insert() do
        {:ok, transaction} ->
          {:ok,
           %DeviceAuthorization{
             state: state,
             user_code: transaction.user_code,
             verification_uri: transaction.verification_uri,
             verification_uri_complete: transaction.verification_uri_complete,
             interval_seconds: transaction.interval_seconds,
             expires_at: transaction.expires_at
           }}

        {:error, changeset} ->
          {:error, changeset}
      end
    else
      {:error, %ProviderError{} = error} -> {:error, provider_error(error)}
      {:error, %Error{} = error} -> {:error, error}
    end
  rescue
    DBConnection.ConnectionError ->
      {:error, Error.new(:temporary, :database_unavailable, "OAuth database is unavailable")}
  end

  @spec poll_device(String.t(), String.t(), Keyword.t()) ::
          {:ok, :authorization_pending}
          | {:ok, {:slow_down, pos_integer()}}
          | {:ok, Token.t(), DeviceConsumed.t()}
          | {:error, Error.t()}
  def poll_device(provider, state, opts \\ []) when is_binary(state) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    with {:ok, transaction} <- load_device_transaction(provider, state),
         :ok <- validate_device_transaction(transaction, provider, now),
         {:ok, device_code} <-
           Crypto.decrypt(
             transaction.device_code_ciphertext,
             device_context(transaction.provider, transaction.mailbox_id)
           ),
         {:ok, adapter, config} <- adapter_config(provider) do
      case adapter.exchange_device_code(device_code, config, provider_opts(opts)) do
        {:ok, %Token{} = token} ->
          finish_device_transaction(transaction, provider, now, token)

        {:pending, :authorization_pending} ->
          {:ok, :authorization_pending}

        {:pending, :slow_down, interval} when is_integer(interval) and interval > 0 ->
          {:ok, {:slow_down, interval}}

        {:error, %ProviderError{} = error} ->
          maybe_consume_failed_device(transaction, now, error)

        {:error, %Error{} = error} ->
          {:error, error}
      end
    end
  rescue
    DBConnection.ConnectionError ->
      {:error, database_error(:unavailable)}
  end

  defp finish_device_transaction(transaction, provider, now, token) do
    Repo.transaction(fn ->
      locked =
        OAuthTransaction
        |> where([row], row.id == ^transaction.id)
        |> lock("FOR UPDATE")
        |> Repo.one()

      cond do
        is_nil(locked) or locked.provider != provider or locked.flow != "device" ->
          Repo.rollback(oauth_error(:oauth_state_mismatch, "OAuth state does not match"))

        not is_nil(locked.consumed_at) ->
          Repo.rollback(oauth_error(:oauth_state_replayed, "OAuth state was already consumed"))

        DateTime.compare(locked.expires_at, now) != :gt ->
          locked
          |> Ecto.Changeset.change(consumed_at: now)
          |> Repo.update!()

          Repo.rollback(oauth_error(:oauth_state_expired, "OAuth device code expired"))

        true ->
          locked
          |> Ecto.Changeset.change(consumed_at: now)
          |> Repo.update!()

          {token,
           %DeviceConsumed{
             provider: locked.provider,
             mailbox_id: locked.mailbox_id
           }}
      end
    end)
    |> case do
      {:ok, {%Token{} = token, %DeviceConsumed{} = consumed}} -> {:ok, token, consumed}
      {:error, %Error{} = error} -> {:error, error}
      {:error, reason} -> {:error, database_error(reason)}
    end
  end

  defp maybe_consume_failed_device(transaction, now, %ProviderError{} = error) do
    if error.code in [:authorization_declined, :device_code_expired, :access_denied] do
      _ =
        transaction
        |> Ecto.Changeset.change(consumed_at: now)
        |> Repo.update()
    end

    {:error, provider_error(error)}
  end

  defp load_device_transaction(provider, state) do
    case Repo.one(
           from(transaction in OAuthTransaction,
             where: transaction.state_digest == ^state_digest(state)
           )
         ) do
      %OAuthTransaction{flow: "device", provider: ^provider} = transaction ->
        {:ok, transaction}

      %OAuthTransaction{} ->
        {:error, oauth_error(:oauth_state_mismatch, "OAuth state does not match")}

      nil ->
        {:error, oauth_error(:oauth_state_mismatch, "OAuth state does not match")}
    end
  end

  defp validate_device_transaction(%OAuthTransaction{consumed_at: consumed_at}, _provider, _now)
       when not is_nil(consumed_at) do
    {:error, oauth_error(:oauth_state_replayed, "OAuth state was already consumed")}
  end

  defp validate_device_transaction(%OAuthTransaction{} = transaction, _provider, now) do
    if DateTime.compare(transaction.expires_at, now) == :gt do
      :ok
    else
      _ =
        transaction
        |> Ecto.Changeset.change(consumed_at: now)
        |> Repo.update()

      {:error, oauth_error(:oauth_state_expired, "OAuth device code expired")}
    end
  end

  defp consume_authorization_code(nil, _provider, _redirect_uri, _now) do
    {:error, oauth_error(:oauth_state_mismatch, "OAuth state does not match")}
  end

  defp consume_authorization_code(
         %OAuthTransaction{consumed_at: consumed_at},
         _provider,
         _redirect,
         _now
       )
       when not is_nil(consumed_at) do
    {:error, oauth_error(:oauth_state_replayed, "OAuth state was already consumed")}
  end

  defp consume_authorization_code(transaction, provider, redirect_uri, now) do
    cond do
      provider not in @providers or transaction.provider != provider or
          transaction.flow != "authorization_code" or
          transaction.redirect_uri != redirect_uri ->
        {:error, oauth_error(:oauth_state_mismatch, "OAuth state does not match")}

      DateTime.compare(transaction.expires_at, now) != :gt ->
        transaction
        |> Ecto.Changeset.change(consumed_at: now)
        |> Repo.update!()

        {:error, oauth_error(:oauth_state_expired, "OAuth state expired")}

      true ->
        with {:ok, verifier} <-
               Crypto.decrypt(
                 transaction.pkce_verifier_ciphertext,
                 verifier_context(transaction.provider, transaction.mailbox_id)
               ) do
          transaction
          |> Ecto.Changeset.change(consumed_at: now)
          |> Repo.update!()

          {:ok,
           %Consumed{
             provider: transaction.provider,
             mailbox_id: transaction.mailbox_id,
             redirect_uri: transaction.redirect_uri,
             pkce_verifier: verifier
           }}
        end
    end
  end

  defp authorization_url(provider, config, redirect_uri, state, verifier) do
    query = [
      client_id: Keyword.fetch!(config, :client_id),
      redirect_uri: redirect_uri,
      response_type: "code",
      scope: Enum.join(scopes(provider), " "),
      state: state,
      code_challenge: pkce_challenge(verifier),
      code_challenge_method: "S256"
    ]

    query =
      case provider do
        "gmail" ->
          query ++ [access_type: "offline", include_granted_scopes: "true", prompt: "consent"]

        "microsoft" ->
          query ++ [response_mode: "query"]
      end

    Keyword.fetch!(config, :authorization_url) <> "?" <> URI.encode_query(query)
  end

  defp scopes("gmail"),
    do: [
      "openid",
      "email",
      "https://www.googleapis.com/auth/gmail.readonly"
    ]

  defp scopes("microsoft"), do: ["openid", "profile", "offline_access", "User.Read", "Mail.Read"]

  defp require_authorization_code_provider("gmail"), do: :ok

  defp require_authorization_code_provider(provider) do
    {:error,
     Error.new(
       :permanent,
       :authorization_code_unsupported,
       "authorization-code OAuth is not used for this provider",
       %{provider: provider}
     )}
  end

  defp require_device_provider("microsoft"), do: :ok

  defp require_device_provider("gmail") do
    {:error,
     Error.new(
       :permanent,
       :device_flow_unsupported,
       "Google device authorization does not allow Gmail API scopes; use authorization code with PKCE",
       %{provider: "gmail"}
     )}
  end

  defp require_device_provider(_provider) do
    {:error, oauth_error(:unsupported_provider, "OAuth provider is not supported")}
  end

  defp provider_config(provider) when provider in @providers do
    providers = Application.get_env(:manifold_connectors, :providers, [])

    case Keyword.get(providers, String.to_existing_atom(provider)) do
      config when is_list(config) ->
        if present?(Keyword.get(config, :client_id)) and
             present?(Keyword.get(config, :authorization_url)) do
          {:ok, config}
        else
          provider_not_configured(provider)
        end

      _missing ->
        provider_not_configured(provider)
    end
  end

  defp provider_config(_provider) do
    {:error, oauth_error(:unsupported_provider, "OAuth provider is not supported")}
  end

  defp adapter_config(provider) when provider in @providers do
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
        if present?(Keyword.get(config, :client_id)) do
          {:ok, adapter, config}
        else
          provider_not_configured(provider)
        end

      _missing ->
        provider_not_configured(provider)
    end
  end

  defp adapter_config(_provider) do
    {:error, oauth_error(:unsupported_provider, "OAuth provider is not supported")}
  end

  defp provider_not_configured(provider) do
    {:error,
     Error.new(
       :permanent,
       :provider_not_configured,
       "OAuth provider is not configured",
       %{provider: provider}
     )}
  end

  defp validate_redirect_uri(uri) do
    parsed = URI.parse(uri)

    if parsed.scheme in ["https", "http"] and is_binary(parsed.host) and parsed.host != "" and
         is_nil(parsed.fragment) do
      :ok
    else
      {:error, oauth_error(:invalid_redirect_uri, "OAuth redirect URI is invalid")}
    end
  end

  defp provider_opts(opts), do: Keyword.get(opts, :provider_opts, Keyword.take(opts, [:now]))

  defp provider_error(%ProviderError{} = error) do
    class = if error.class == :temporary, do: :temporary, else: :permanent

    Error.new(class, error.code, error.message, %{
      provider_class: error.class,
      retry_after_seconds: error.retry_after_seconds
    })
  end

  defp random_url_token,
    do: 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  defp state_digest(state), do: :crypto.hash(:sha256, state)

  defp pkce_challenge(verifier) do
    verifier
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.url_encode64(padding: false)
  end

  defp verifier_context(provider, mailbox_id), do: "oauth:" <> provider <> ":" <> mailbox_id

  defp device_context(provider, mailbox_id),
    do: "oauth-device:" <> provider <> ":" <> mailbox_id

  defp present?(value), do: is_binary(value) and value != ""

  defp oauth_error(reason, message), do: Error.new(:permanent, reason, message)

  defp database_error(reason) do
    Error.new(:temporary, :database_unavailable, "OAuth database operation failed", %{
      reason: inspect(reason)
    })
  end
end
