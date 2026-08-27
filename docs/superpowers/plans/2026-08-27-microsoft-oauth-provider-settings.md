# Microsoft OAuth Provider Settings Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Configure Microsoft 365 OAuth client credentials through `/settings/oauth`, remove Microsoft client-credential environment configuration, and apply the same encrypted storage and generation fencing used by Google.

**Architecture:** Register Microsoft in the trusted OAuth provider catalog and reuse the existing provider-neutral settings table, encryption, LiveViews, and lifecycle transactions. Resolve Microsoft credentials from PostgreSQL for every OAuth, sync, and send operation while keeping the `organizations` tenant and endpoint authority in trusted code. Cut over without importing or falling back to legacy environment credentials.

**Tech Stack:** Elixir 1.18, Phoenix LiveView, Ecto/PostgreSQL, Microsoft Graph OAuth 2.0, ExUnit, Req, Oban, Devenv

---

## Scope and execution constraints

- Execute in `.trees/microsoft-oauth-provider-settings` on branch
  `codex/microsoft-oauth-provider-settings`.
- Preserve the unrelated untracked main-checkout file
  `docs/superpowers/plans/2026-08-10-account-disable-async-delete.md`.
- Do not add or edit a migration. `connector_oauth_provider_settings` and the
  paired OAuth transaction generation columns are already provider-neutral.
- Do not add personal Outlook.com, `common`, `consumers`, tenant editing,
  `Mail.ReadWrite`, application permissions, aliases, or shared-mailbox support.
- Do not import, read, or fall back to
  `MANIFOLD_MICROSOFT_CLIENT_ID` or
  `MANIFOLD_MICROSOFT_CLIENT_SECRET` in production code.
- Keep `MANIFOLD_CONNECTOR_ENCRYPTION_KEY` as the stable out-of-database master
  key. Keep only the Microsoft authorization, token, and Graph endpoint override
  variables.
- Run database-backed suites sequentially; they share the local PostgreSQL test
  database.

## File map

### Create

- `apps/manifold_connectors/lib/manifold/connectors/oauth_provider/microsoft.ex`
  — trusted Microsoft catalog definition and help metadata.

### Modify: connector configuration and OAuth boundaries

- `apps/manifold_connectors/lib/manifold/connectors/oauth_provider_catalog.ex`
- `apps/manifold_connectors/lib/manifold/connectors/provider_config.ex`
- `apps/manifold_connectors/lib/manifold/connectors/oauth.ex`
- `apps/manifold_connectors/lib/manifold/connectors.ex`
- `apps/manifold_connectors/lib/manifold/connectors/oauth_authorizations.ex`
- `apps/manifold_connectors/lib/manifold/connectors/sync.ex`
- `config/runtime.exs`

### Modify: focused tests and fixtures

- `apps/manifold_data/test/manifold/config_test.exs`
- `apps/manifold_connectors/test/manifold/connectors/oauth_provider_catalog_test.exs`
- `apps/manifold_connectors/test/manifold/connectors/provider_settings_test.exs`
- `apps/manifold_connectors/test/manifold/connectors/provider_config_test.exs`
- `apps/manifold_connectors/test/manifold/connectors/oauth_test.exs`
- `apps/manifold_connectors/test/manifold/connectors/microsoft_authorizations_test.exs`
- `apps/manifold_connectors/test/manifold/connectors/submission_method_test.exs`
- `apps/manifold_connectors/test/manifold/connectors/sync_test.exs`
- `apps/manifold_connectors/test/manifold/connectors_test.exs`
- `apps/manifold_outbound/test/manifold/outbound/jobs/submit_outbound_test.exs`
- `apps/manifold_outbound/test/manifold/outbound/submission_test.exs`
- `apps/manifold_web/test/manifold_web/oauth_settings_live_test.exs`
- `apps/manifold_web/test/manifold_web/account_live_test.exs`
- `apps/manifold_web/test/manifold_web/external_accounts_web_test.exs`

### Modify: operator and feature documentation

- `README.md`
- `AGENTS.md`
- `docs/DESIGN.md`
- `docs/MILESTONE_6_PLAN.md`
- `docs/superpowers/specs/2026-08-11-microsoft-365-receive-send-methods-design.md`
- `docs/superpowers/specs/2026-08-18-oauth-provider-settings-design.md`
- `.agents/skills/develop/references/oauth-provider-settings.md`
- `.agents/skills/develop/references/microsoft-365-receive-send-methods.md`
- `.agents/skills/develop/references/gmail-receive-send-methods.md`

---

### Task 1: Register Microsoft in the OAuth provider catalog and generic Settings UI

**Files:**
- Create: `apps/manifold_connectors/lib/manifold/connectors/oauth_provider/microsoft.ex`
- Modify: `apps/manifold_connectors/lib/manifold/connectors/oauth_provider_catalog.ex`
- Test: `apps/manifold_connectors/test/manifold/connectors/oauth_provider_catalog_test.exs`
- Test: `apps/manifold_web/test/manifold_web/oauth_settings_live_test.exs`

- [ ] **Step 1: Write the failing catalog test**

Replace the Gmail-only catalog assertion with an exact two-provider assertion:

```elixir
test "catalog exposes Gmail then Microsoft with trusted definitions" do
  assert [
           %{key: "gmail", name: "Gmail"} = gmail,
           %{key: "microsoft", name: "Microsoft 365"} = microsoft
         ] = OAuthProviderCatalog.list()

  assert {:ok, ^gmail} = OAuthProviderCatalog.fetch("gmail")
  assert {:ok, ^microsoft} = OAuthProviderCatalog.fetch("microsoft")
  assert microsoft.icon == "microsoft"
  assert microsoft.callback_path == "/connectors/microsoft/callback"
  assert microsoft.capabilities == [:receive, :send]

  assert microsoft.scopes == [
           "openid",
           "profile",
           "User.Read",
           "Mail.Read",
           "Mail.Send",
           "offline_access"
         ]

  assert microsoft.runtime_config == [
           authorization_url:
             "https://login.microsoftonline.com/organizations/oauth2/v2.0/authorize",
           token_url:
             "https://login.microsoftonline.com/organizations/oauth2/v2.0/token",
           base_url: "https://graph.microsoft.com/v1.0",
           tenant: "organizations"
         ]

  assert microsoft.help.configuration_title == "Microsoft OAuth"
  assert microsoft.help.documentation_name == "Microsoft"
  assert Enum.any?(microsoft.help.steps, &String.contains?(&1, "work/school"))
  assert Enum.any?(microsoft.help.steps, &String.contains?(&1, "Do not add Mail.ReadWrite"))
end
```

Keep the complete existing Gmail definition assertions; do not weaken them.

- [ ] **Step 2: Write failing LiveView render and help tests**

Extend the settings render test:

```elixir
assert has_element?(view, "#oauth-provider-gmail")
assert has_element?(view, "#oauth-provider-microsoft")

assert has_element?(
         view,
         "#oauth-provider-microsoft-client-secret[type='password'][value='']"
       )

assert has_element?(
         view,
         "#oauth-provider-microsoft-callback[readonly][value='http://localhost:4002/connectors/microsoft/callback']"
       )

assert html =~ "/settings/oauth/microsoft/help"
refute html =~ "MANIFOLD_MICROSOFT_CLIENT_ID"
refute html =~ "MANIFOLD_MICROSOFT_CLIENT_SECRET"
```

Add a help-page test:

```elixir
test "Microsoft OAuth help is catalog-driven and work-school scoped", %{conn: conn} do
  {:ok, view, html} = live(conn, "/settings/oauth/microsoft/help")

  assert has_element?(view, "#oauth-provider-microsoft-help-title", "Set up Microsoft OAuth")
  assert has_element?(view, "#oauth-provider-microsoft-help-callback[readonly]")
  assert html =~ "http://localhost:4002/connectors/microsoft/callback"

  for scope <- ~w(openid profile User.Read Mail.Read Mail.Send offline_access) do
    assert has_element?(view, ~s([data-scope="#{scope}"]))
  end

  assert html =~ "work/school"
  assert html =~ "organizations"
  assert html =~ "personal Outlook.com accounts are not supported"
  assert html =~ "Do not add Mail.ReadWrite"
end
```

- [ ] **Step 3: Run the focused tests to verify RED**

```sh
devenv shell -- mix test \
  apps/manifold_connectors/test/manifold/connectors/oauth_provider_catalog_test.exs \
  apps/manifold_web/test/manifold_web/oauth_settings_live_test.exs
```

Expected: failures because the catalog lists only Gmail and Microsoft help is
unavailable.

- [ ] **Step 4: Add the trusted Microsoft definition**

Create `oauth_provider/microsoft.ex`:

```elixir
defmodule Manifold.Connectors.OAuthProvider.Microsoft do
  @moduledoc false

  @definition %{
    key: "microsoft",
    name: "Microsoft 365",
    icon: "microsoft",
    callback_path: "/connectors/microsoft/callback",
    capabilities: [:receive, :send],
    scopes: ["openid", "profile", "User.Read", "Mail.Read", "Mail.Send", "offline_access"],
    runtime_config: [
      authorization_url:
        "https://login.microsoftonline.com/organizations/oauth2/v2.0/authorize",
      token_url:
        "https://login.microsoftonline.com/organizations/oauth2/v2.0/token",
      base_url: "https://graph.microsoft.com/v1.0",
      tenant: "organizations"
    ],
    help: %{
      title: "Set up Microsoft OAuth",
      configuration_title: "Microsoft OAuth",
      documentation_name: "Microsoft",
      steps: [
        "Create or select a Microsoft Entra application registration.",
        "Select accounts in any organizational directory for work/school access.",
        "Add a Web platform and register the exact callback URI shown below.",
        "Add delegated User.Read, Mail.Read, and Mail.Send permissions.",
        "Do not add Mail.ReadWrite; Manifold does not create or modify Graph drafts.",
        "Allow offline_access so Manifold can refresh the delegated grant.",
        "Create a client secret and copy its value before leaving the Entra page.",
        "Copy the application client ID and secret into Settings OAuth.",
        "Obtain tenant administrator consent when the tenant policy requires it."
      ],
      scopes: [
        %{value: "openid", purpose: "Confirm the Microsoft identity."},
        %{value: "profile", purpose: "Read the signed-in account profile."},
        %{value: "User.Read", purpose: "Read and bind the signed-in Graph identity."},
        %{value: "Mail.Read", purpose: "Receive mail without modifying the remote mailbox."},
        %{value: "Mail.Send", purpose: "Send mail as the signed-in user."},
        %{value: "offline_access", purpose: "Refresh the delegated grant when access expires."}
      ],
      testing_note:
        "Use non-production Microsoft 365 work/school accounts; personal Outlook.com accounts are not supported.",
      production_note:
        "The organizations tenant accepts work/school identities, and tenant policy may require administrator consent.",
      links: [
        {"Register an Entra application",
         "https://learn.microsoft.com/en-us/entra/identity-platform/quickstart-register-app"},
        {"Configure a redirect URI",
         "https://learn.microsoft.com/en-us/entra/identity-platform/how-to-add-redirect-uri"},
        {"Microsoft Graph permissions",
         "https://learn.microsoft.com/en-us/graph/permissions-reference"},
        {"Supported organizational account types",
         "https://learn.microsoft.com/en-us/entra/identity-platform/howto-modify-supported-accounts"}
      ]
    }
  }

  @spec definition() :: map()
  def definition, do: @definition
end
```

- [ ] **Step 5: Register Microsoft after Gmail**

```elixir
alias Manifold.Connectors.OAuthProvider.{Gmail, Microsoft}

@spec list() :: [map()]
def list, do: [Gmail.definition(), Microsoft.definition()]

@spec fetch(String.t()) :: {:ok, map()} | {:error, Error.t()}
def fetch("gmail"), do: {:ok, Gmail.definition()}
def fetch("microsoft"), do: {:ok, Microsoft.definition()}
```

Leave the unknown-provider clause unchanged.

- [ ] **Step 6: Run the focused tests to verify GREEN**

Run the command from Step 3.

Expected: both test files pass and the generic LiveViews render Microsoft.

- [ ] **Step 7: Commit**

```sh
git add \
  apps/manifold_connectors/lib/manifold/connectors/oauth_provider/microsoft.ex \
  apps/manifold_connectors/lib/manifold/connectors/oauth_provider_catalog.ex \
  apps/manifold_connectors/test/manifold/connectors/oauth_provider_catalog_test.exs \
  apps/manifold_web/test/manifold_web/oauth_settings_live_test.exs
git commit -m "feat(connectors): catalog Microsoft OAuth settings"
```

---

### Task 2: Prove generic Microsoft storage and lifecycle isolation

**Files:**
- Test: `apps/manifold_connectors/test/manifold/connectors/provider_settings_test.exs`

- [ ] **Step 1: Update safe-list expectations for both providers**

```elixir
assert {:ok, [gmail_missing, microsoft_missing]} =
         Connectors.list_oauth_provider_settings()

assert gmail_missing.provider == "gmail"
assert gmail_missing.status == :not_configured
assert microsoft_missing.provider == "microsoft"
assert microsoft_missing.status == :not_configured
```

- [ ] **Step 2: Add a Microsoft lifecycle isolation test**

```elixir
test "Microsoft save rotation and removal affect only Microsoft dependencies" do
  gmail = insert_oauth_family!("gmail", "microsoft-isolation-gmail")
  microsoft = insert_oauth_family!("microsoft", "microsoft-isolation")
  gmail_snapshot = family_snapshot(gmail)

  assert {:ok, created} =
           Connectors.put_oauth_provider_setting(
             "microsoft",
             %{"client_id" => "microsoft-client", "client_secret" => "secret-one"},
             expected_lock_version: nil
           )

  assert_reconnect_required(microsoft)
  assert family_snapshot(gmail) == gmail_snapshot

  second = insert_oauth_family!("microsoft", "microsoft-rotation")

  assert {:ok, rotated} =
           Connectors.put_oauth_provider_setting(
             "microsoft",
             %{"client_id" => "microsoft-client", "client_secret" => "secret-two"},
             expected_lock_version: created.lock_version
           )

  assert rotated.lock_version == created.lock_version + 1
  assert_reconnect_required(second)
  assert family_snapshot(gmail) == gmail_snapshot

  assert {:ok, %{status: :not_configured}} =
           Connectors.remove_oauth_provider_setting(
             "microsoft",
             expected_lock_version: rotated.lock_version
           )

  refute Repo.get_by(OAuthProviderSetting, provider: "microsoft")
  assert family_snapshot(gmail) == gmail_snapshot
end
```

- [ ] **Step 3: Run the test**

```sh
devenv shell -- mix test \
  apps/manifold_connectors/test/manifold/connectors/provider_settings_test.exs
```

Expected: PASS using the existing provider-generic production code. If it fails,
fix only provider-generic assumptions; do not create Microsoft-specific storage.

- [ ] **Step 4: Commit**

```sh
git add apps/manifold_connectors/test/manifold/connectors/provider_settings_test.exs
git commit -m "test(connectors): cover Microsoft OAuth setting lifecycle"
```

---

### Task 3: Resolve Microsoft credentials from encrypted database settings

**Files:**
- Modify: `apps/manifold_connectors/lib/manifold/connectors/provider_config.ex`
- Test: `apps/manifold_connectors/test/manifold/connectors/provider_config_test.exs`

- [ ] **Step 1: Replace environment-backed Microsoft resolver tests**

Add a generic helper:

```elixir
defp put_setting!(provider, client_id, client_secret) do
  assert {:ok, _view} =
           Connectors.put_oauth_provider_setting(
             provider,
             %{"client_id" => client_id, "client_secret" => client_secret},
             expected_lock_version: nil
           )

  Repo.get_by!(OAuthProviderSetting, provider: provider)
end
```

Replace the old Microsoft application-credential tests with:

```elixir
test "Microsoft resolver combines stored credentials with trusted fixed configuration" do
  secret = "microsoft-db-secret-not-for-inspection"
  setting = put_setting!("microsoft", "microsoft-db-client", secret)

  Application.put_env(:manifold_connectors, :providers,
    microsoft: [
      client_id: "ignored-client",
      client_secret: "ignored-secret",
      authorization_url: "https://login.example/authorize",
      token_url: "https://login.example/token",
      base_url: "https://graph.example/v1.0",
      tenant: "consumers",
      req_options: [
        plug: {Req.Test, __MODULE__},
        headers: [{"authorization", "ignored-header-secret"}]
      ],
      untrusted_extra: "ignored"
    ]
  )

  assert {:ok, %ProviderConfig.Resolved{} = resolved} =
           ProviderConfig.fetch("microsoft")

  assert resolved.setting_id == setting.id
  assert resolved.setting_lock_version == setting.lock_version

  assert Map.new(resolved.config) == %{
           client_id: "microsoft-db-client",
           client_secret: secret,
           authorization_url: "https://login.example/authorize",
           token_url: "https://login.example/token",
           base_url: "https://graph.example/v1.0",
           tenant: "organizations",
           req_options: [plug: {Req.Test, __MODULE__}]
         }

  refute inspect(resolved) =~ secret
  refute inspect(resolved.config) =~ "ignored-secret"
  refute inspect(resolved.config) =~ "ignored-header-secret"
  refute Keyword.has_key?(resolved.config, :untrusted_extra)
end

test "legacy Microsoft application credentials cannot configure the provider" do
  Application.put_env(:manifold_connectors, :providers,
    microsoft: [
      client_id: "legacy-client",
      client_secret: "legacy-secret",
      authorization_url:
        "https://login.microsoftonline.com/organizations/oauth2/v2.0/authorize"
    ]
  )

  assert {:error, %Error{reason: :provider_not_configured}} =
           ProviderConfig.fetch("microsoft")
end
```

Add explicit corruption and discovery tests:

```elixir
test "corrupt Microsoft settings fail closed without leaking crypto details" do
  secret = "microsoft-corrupt-secret"
  setting = put_setting!("microsoft", "microsoft-client", secret)

  {:ok, corrupt_ciphertext} =
    Manifold.Connectors.Crypto.encrypt(secret, "wrong-microsoft-setting-context")

  OAuthProviderSetting
  |> where([candidate], candidate.id == ^setting.id)
  |> Repo.update_all(set: [client_secret_ciphertext: corrupt_ciphertext])

  assert {:error, %Error{reason: :provider_configuration_error} = error} =
           ProviderConfig.fetch("microsoft")

  refute inspect(error) =~ secret
  refute inspect(error) =~ "credential_authentication_failed"
  refute inspect(error) =~ "ciphertext"
end

test "configured providers reflects independent stored settings immediately" do
  assert Connectors.configured_providers() == []

  gmail = put_setting!("gmail", "gmail-client", "gmail-secret")
  assert Connectors.configured_providers() == ["gmail"]

  microsoft = put_setting!("microsoft", "microsoft-client", "microsoft-secret")
  assert Connectors.configured_providers() == ["gmail", "microsoft"]

  assert {:ok, _view} =
           Connectors.remove_oauth_provider_setting(
             "microsoft",
             expected_lock_version: microsoft.lock_version
           )

  assert Connectors.configured_providers() == ["gmail"]
  assert Repo.get!(OAuthProviderSetting, gmail.id)
end
```

- [ ] **Step 2: Run resolver tests to verify RED**

```sh
devenv shell -- mix test \
  apps/manifold_connectors/test/manifold/connectors/provider_config_test.exs
```

Expected: Microsoft returns application credentials with nil generation or
reports configured without a database row.

- [ ] **Step 3: Generalize `ProviderConfig.fetch/1`**

```elixir
@providers ~w(gmail microsoft)
@endpoint_keys [:authorization_url, :token_url, :userinfo_url, :base_url]

@spec fetch(String.t()) :: {:ok, Resolved.t()} | {:error, Error.t()}
def fetch(provider) when provider in @providers do
  with {:ok, definition} <- OAuthProviderCatalog.fetch(provider),
       {:ok, credentials} <- ProviderSettings.runtime_credentials(provider) do
    config =
      definition
      |> runtime_config(provider)
      |> Keyword.put(:client_id, credentials.client_id)
      |> Keyword.put(:client_secret, credentials.client_secret)

    {:ok,
     %Resolved{
       provider: provider,
       config: config,
       setting_id: credentials.setting_id,
       setting_lock_version: credentials.setting_lock_version
     }}
  else
    {:error, %Error{reason: :oauth_provider_not_configured}} ->
      {:error, provider_not_configured_error()}

    {:error, %Error{reason: :oauth_provider_configuration_error}} ->
      {:error, provider_configuration_error()}

    {:error, %Error{} = error} ->
      {:error, error}
  end
end
```

Replace Gmail-only helpers with:

```elixir
defp runtime_config(definition, provider) do
  application_config = provider_application_config(provider)

  configured_endpoints =
    application_config
    |> Keyword.take(@endpoint_keys)
    |> Enum.filter(fn {_key, value} -> is_binary(value) and value != "" end)

  safe_req_options =
    application_config
    |> Keyword.get(:req_options, [])
    |> then(fn
      options when is_list(options) -> Keyword.take(options, [:plug])
      _other -> []
    end)

  definition.runtime_config
  |> Keyword.merge(configured_endpoints)
  |> maybe_put_req_options(safe_req_options)
end

defp provider_application_config(provider) do
  case Application.get_env(:manifold_connectors, :providers, []) do
    providers when is_list(providers) ->
      case Keyword.get(providers, String.to_existing_atom(provider), []) do
        config when is_list(config) -> config
        _other -> []
      end

    _other ->
      []
  end
end
```

The guarded public clause ensures `String.to_existing_atom/1` never sees
untrusted input. Remove `configured?/1` and the old Microsoft clause.

Update the existing database-error assertions so both database-backed providers
fail closed together:

```elixir
assert_database_unavailable(ProviderConfig.fetch("gmail"))
assert_database_unavailable(ProviderConfig.fetch("microsoft"))
assert Connectors.configured_providers() == []
```

- [ ] **Step 4: Run resolver tests to verify GREEN**

Run the command from Step 2.

Expected: both providers have non-nil generations and secret-safe failures.

- [ ] **Step 5: Commit**

```sh
git add \
  apps/manifold_connectors/lib/manifold/connectors/provider_config.ex \
  apps/manifold_connectors/test/manifold/connectors/provider_config_test.exs
git commit -m "feat(connectors): resolve Microsoft OAuth settings"
```

---

### Task 4: Remove Microsoft client credentials and tenant from runtime environment configuration

**Files:**
- Modify: `config/runtime.exs`
- Test: `apps/manifold_data/test/manifold/config_test.exs`

- [ ] **Step 1: Rewrite runtime tests for the database-only cutover**

Keep the legacy names in `@runtime_env_vars` only so tests can clear and inject
them. Replace Microsoft credential-loading assertions with:

```elixir
test "production runtime ignores legacy OAuth credentials and fixes Microsoft organizations endpoints" do
  encryption_key = Base.encode64(:crypto.strong_rand_bytes(32))

  put_runtime_env(%{
    "RELEASE_NAME" => "manifold",
    "MANIFOLD_CONNECTOR_ENCRYPTION_KEY" => encryption_key,
    "MANIFOLD_GMAIL_CLIENT_ID" => "gmail-id",
    "MANIFOLD_GMAIL_CLIENT_SECRET" => "gmail-secret",
    "MANIFOLD_MICROSOFT_CLIENT_ID" => "microsoft-id",
    "MANIFOLD_MICROSOFT_CLIENT_SECRET" => "microsoft-secret",
    "MANIFOLD_MICROSOFT_TENANT" => "consumers",
    "MANIFOLD_MICROSOFT_AUTHORIZATION_URL" => "https://login.example/authorize",
    "MANIFOLD_MICROSOFT_TOKEN_URL" => "https://login.example/token",
    "MANIFOLD_MICROSOFT_API_BASE_URL" => "https://graph.example/v1.0",
    "SECRET_KEY_BASE" => String.duplicate("s", 64)
  })

  connectors = read_runtime(:prod)[:manifold_connectors]
  microsoft = connectors[:providers][:microsoft]

  assert connectors[:encryption_key] == encryption_key
  assert microsoft == [
           authorization_url: "https://login.example/authorize",
           token_url: "https://login.example/token",
           base_url: "https://graph.example/v1.0",
           tenant: "organizations"
         ]

  refute Keyword.has_key?(microsoft, :client_id)
  refute Keyword.has_key?(microsoft, :client_secret)
end

test "development runtime ignores complete and partial legacy Microsoft credentials" do
  for legacy_env <- [
        %{"MANIFOLD_MICROSOFT_CLIENT_ID" => "legacy-id"},
        %{"MANIFOLD_MICROSOFT_CLIENT_SECRET" => "legacy-secret"},
        %{
          "MANIFOLD_MICROSOFT_CLIENT_ID" => "legacy-id",
          "MANIFOLD_MICROSOFT_CLIENT_SECRET" => "legacy-secret"
        }
      ] do
    put_runtime_env(legacy_env)
    microsoft = read_runtime(:dev)[:manifold_connectors][:providers][:microsoft]
    refute Keyword.has_key?(microsoft, :client_id)
    refute Keyword.has_key?(microsoft, :client_secret)
    assert microsoft[:tenant] == "organizations"
  end
end
```

- [ ] **Step 2: Run config tests to verify RED**

```sh
devenv shell -- mix test apps/manifold_data/test/manifold/config_test.exs
```

Expected: the current runtime reads the legacy pair and accepts the tenant
override.

- [ ] **Step 3: Remove credential and tenant environment reads**

Delete `provider_credentials!`, the `MANIFOLD_MICROSOFT_TENANT` read and
validation, and all Microsoft client credential reads. Build only trusted
non-secret configuration:

```elixir
microsoft_tenant = "organizations"
microsoft_tenant_base =
  "https://login.microsoftonline.com/#{microsoft_tenant}/oauth2/v2.0"

microsoft_config = [
  authorization_url:
    https_endpoint!.(
      "MANIFOLD_MICROSOFT_AUTHORIZATION_URL",
      microsoft_tenant_base <> "/authorize"
    ),
  token_url:
    https_endpoint!.(
      "MANIFOLD_MICROSOFT_TOKEN_URL",
      microsoft_tenant_base <> "/token"
    ),
  base_url:
    https_endpoint!.(
      "MANIFOLD_MICROSOFT_API_BASE_URL",
      "https://graph.microsoft.com/v1.0"
    ),
  tenant: microsoft_tenant
]

connector_providers = [gmail: gmail_config, microsoft: microsoft_config]
```

Do not access PostgreSQL from `runtime.exs` and do not add another credential
source.

- [ ] **Step 4: Run config tests to verify GREEN**

Run the command from Step 2.

Expected: endpoint validation remains strict, tenant is always `organizations`,
and neither legacy credential is present in application config.

- [ ] **Step 5: Commit**

```sh
git add config/runtime.exs apps/manifold_data/test/manifold/config_test.exs
git commit -m "feat(config): remove Microsoft OAuth credential env"
```

---

### Task 5: Fence Microsoft OAuth transactions with provider-setting generations

**Files:**
- Modify: `apps/manifold_connectors/lib/manifold/connectors/oauth.ex`
- Test: `apps/manifold_connectors/test/manifold/connectors/oauth_test.exs`

- [ ] **Step 1: Store Microsoft settings in OAuth test setup**

Keep only endpoint/test options in application config and save both settings:

```elixir
Application.put_env(:manifold_connectors, :providers,
  gmail: [authorization_url: "https://accounts.google.test/o/oauth2/v2/auth"],
  microsoft: [
    authorization_url: "https://login.microsoft.test/oauth2/v2.0/authorize",
    token_url: "https://login.microsoft.test/oauth2/v2.0/token",
    base_url: "https://graph.microsoft.test/v1.0",
    tenant: "organizations"
  ]
)

for {provider, client_id, client_secret} <- [
      {"gmail", "gmail-db-client", "gmail-db-secret"},
      {"microsoft", "microsoft-db-client", "microsoft-db-secret"}
    ] do
  assert {:ok, _view} =
           Connectors.put_oauth_provider_setting(provider, %{
             "client_id" => client_id,
             "client_secret" => client_secret
           })
end
```

Load and return both `OAuthProviderSetting` rows from setup.

- [ ] **Step 2: Require Microsoft transaction snapshots and invalidation**

Update the Microsoft receive/send test:

```elixir
assert consumed_receive.oauth_provider_setting_id == microsoft_setting.id
assert consumed_receive.oauth_provider_setting_lock_version == microsoft_setting.lock_version

assert Repo.all(OAuthTransaction)
       |> Enum.all?(fn transaction ->
         transaction.oauth_provider_setting_id == microsoft_setting.id and
           transaction.oauth_provider_setting_lock_version == microsoft_setting.lock_version
       end)
```

Add rotation and legacy-state tests:

```elixir
test "Microsoft setting rotation invalidates an in-flight state", %{
  mailbox: mailbox,
  microsoft_setting: setting
} do
  assert {:ok, authorization} =
           OAuth.start("microsoft", mailbox.id, @microsoft_redirect, purpose: :receive)

  assert {:ok, _rotated} =
           Connectors.put_oauth_provider_setting(
             "microsoft",
             %{"client_id" => "rotated", "client_secret" => "rotated-secret"},
             expected_lock_version: setting.lock_version
           )

  assert {:error, %{reason: :provider_configuration_changed}} =
           OAuth.consume("microsoft", authorization.state, @microsoft_redirect)
end

test "pre-cutover Microsoft transactions are deleted and rejected", %{mailbox: mailbox} do
  now = ~U[2026-08-27 01:00:00.000000Z]
  {state, _verifier} =
    insert_legacy_transaction!("microsoft", mailbox.id, @microsoft_redirect, now)

  assert {:error, %{reason: :provider_configuration_changed}} =
           OAuth.consume(
             "microsoft",
             state,
             @microsoft_redirect,
             now: DateTime.add(now, 60, :second)
           )

  assert Repo.aggregate(OAuthTransaction, :count) == 0
end
```

Delete the previous successful legacy Microsoft consumption test.

- [ ] **Step 3: Run OAuth tests to verify RED**

```sh
devenv shell -- mix test apps/manifold_connectors/test/manifold/connectors/oauth_test.exs
```

Expected: Microsoft consumes nil generations and does not invalidate rotation.

- [ ] **Step 4: Generalize transaction generation validation**

```elixir
defp validate_transaction_generation(%OAuthTransaction{
       provider: provider,
       oauth_provider_setting_id: setting_id,
       oauth_provider_setting_lock_version: setting_lock_version
     })
     when provider in @providers and is_binary(setting_id) and
            is_integer(setting_lock_version) do
  case ProviderConfig.fetch(provider) do
    {:ok,
     %ProviderConfig.Resolved{
       provider: ^provider,
       setting_id: ^setting_id,
       setting_lock_version: ^setting_lock_version
     }} ->
      :ok

    {:ok, %ProviderConfig.Resolved{}} ->
      provider_configuration_changed()

    {:error, %Error{reason: reason}}
    when reason in [:provider_not_configured, :provider_configuration_error] ->
      provider_configuration_changed()

    {:error, %Error{} = error} ->
      {:error, error}
  end
end

defp validate_transaction_generation(%OAuthTransaction{provider: provider})
     when provider in @providers,
     do: provider_configuration_changed()
```

Delete nil-generation transactions for both supported providers:

```elixir
defp consume_invalidated_transaction(
       %OAuthTransaction{
         provider: provider,
         oauth_provider_setting_id: nil,
         oauth_provider_setting_lock_version: nil
       } = transaction,
       _now,
       error
     )
     when provider in @providers do
  Repo.delete!(transaction)
  {:error, error}
end
```

- [ ] **Step 5: Run OAuth tests to verify GREEN**

Run the command from Step 3.

Expected: both providers carry non-nil settings generations.

- [ ] **Step 6: Commit**

```sh
git add \
  apps/manifold_connectors/lib/manifold/connectors/oauth.ex \
  apps/manifold_connectors/test/manifold/connectors/oauth_test.exs
git commit -m "fix(connectors): fence Microsoft OAuth transactions"
```

---

### Task 6: Carry Microsoft generations through completion, persistence, refresh, and sync

**Files:**
- Modify: `apps/manifold_connectors/lib/manifold/connectors.ex`
- Modify: `apps/manifold_connectors/lib/manifold/connectors/oauth_authorizations.ex`
- Modify: `apps/manifold_connectors/lib/manifold/connectors/sync.ex`
- Test: `apps/manifold_connectors/test/manifold/connectors/microsoft_authorizations_test.exs`
- Test: `apps/manifold_connectors/test/manifold/connectors/sync_test.exs`

- [ ] **Step 1: Convert Microsoft authorization setup to stored credentials**

Keep endpoints in application config and save a setting:

```elixir
Application.put_env(:manifold_connectors, :providers,
  microsoft: [
    authorization_url: "https://login.microsoft.test/authorize",
    token_url: "https://login.microsoft.test/token",
    base_url: "https://graph.microsoft.test/v1.0",
    tenant: "organizations"
  ]
)

assert {:ok, setting_view} =
         Connectors.put_oauth_provider_setting("microsoft", %{
           "client_id" => "microsoft-db-client",
           "client_secret" => "microsoft-db-secret"
         })

setting = Repo.get_by!(OAuthProviderSetting, provider: "microsoft")
```

Add `OAuthProviderSetting` to the schema alias and return both setting forms from
setup.

Update the existing `complete/4` helper so every direct Microsoft completion
also carries the current setting generation:

```elixir
setting = Repo.get_by!(OAuthProviderSetting, provider: "microsoft")

consumed = %Consumed{
  provider: "microsoft",
  mailbox_id: account.id,
  purpose: purpose,
  required_scopes: required_scopes,
  redirect_uri: "https://mail.example.test/connectors/microsoft/callback",
  pkce_verifier: "verifier-secret",
  oauth_provider_setting_id: setting.id,
  oauth_provider_setting_lock_version: setting.lock_version
}
```

- [ ] **Step 2: Instrument the fake provider and write completion tests**

```elixir
def exchange_code(_code, _verifier, _redirect_uri, config, opts) do
  if test_pid = Keyword.get(opts, :test_pid) do
    send(test_pid, {:microsoft_exchange_config, config})
    send(test_pid, {:exchange_required_scopes, Keyword.get(opts, :required_scopes)})
  end

  if gate = Keyword.get(opts, :exchange_gate) do
    test_pid = Keyword.fetch!(opts, :test_pid)
    send(test_pid, {:microsoft_exchange_started, self(), gate})

    receive do
      {:release_microsoft_exchange, ^gate} -> :ok
    end
  end

  Keyword.fetch!(opts, :token)
end

def identity(_access_token, config, opts) do
  if test_pid = Keyword.get(opts, :test_pid) do
    send(test_pid, {:microsoft_identity_config, config})
  end

  Keyword.fetch!(opts, :identity)
end
```

Add:

```elixir
test "unchanged Microsoft setting generation completes with stored credentials", %{
  account: account,
  address: address,
  setting: setting
} do
  consumed = start_and_consume_microsoft!(account.id, :receive)
  assert consumed.oauth_provider_setting_id == setting.id
  assert consumed.oauth_provider_setting_lock_version == setting.lock_version

  assert {:ok, %ReceiveMethod{status: "connected"}} =
           Connectors.complete_authorization(
             "microsoft",
             "authorization-code",
             consumed,
             now: @now,
             provider_opts: completion_provider_opts(address, test_pid: self())
           )

  assert_receive {:microsoft_exchange_config, config}
  assert_receive {:microsoft_identity_config, ^config}
  assert config[:client_id] == "microsoft-db-client"
  assert config[:client_secret] == "microsoft-db-secret"
end
```

Define the helper used by that test:

```elixir
defp start_and_consume_microsoft!(account_id, purpose) do
  redirect_uri = "https://mail.example.test/connectors/microsoft/callback"
  assert {:ok, started} = OAuth.start("microsoft", account_id, redirect_uri, purpose: purpose)
  assert {:ok, consumed} = OAuth.consume("microsoft", started.state, redirect_uri)
  consumed
end

defp completion_provider_opts(address, extra) do
  token = %Token{
    access_token: "access-secret",
    refresh_token: "refresh-secret",
    expires_at: @expires_at,
    scopes: access_token_scopes(purpose_scopes(:receive))
  }

  identity = %Identity{id: @subject, email_address: address}
  Keyword.merge([token: {:ok, token}, identity: {:ok, identity}], extra)
end
```

Add a gated exchange test that rotates the setting after
`{:microsoft_exchange_started, ...}` and asserts
`provider_configuration_changed` with no authorization, method, event, cursor,
or Oban job persisted.

- [ ] **Step 3: Write a sync resolver test**

Save a Microsoft setting in `sync_test.exs` setup, remove its placeholder
application client credential, instrument one Microsoft `sync_page/4` call, and
assert:

```elixir
assert_receive {:microsoft_sync_config, config}
assert config[:client_id] == "microsoft-db-client"
assert config[:client_secret] == "microsoft-db-secret"
assert config[:base_url] == "https://graph.microsoft.test/v1.0"
```

- [ ] **Step 4: Run focused tests to verify RED**

```sh
devenv shell -- mix test \
  apps/manifold_connectors/test/manifold/connectors/microsoft_authorizations_test.exs \
  apps/manifold_connectors/test/manifold/connectors/sync_test.exs
```

Expected: Microsoft completion and sync still bypass `ProviderConfig`, and final
persistence does not require the Microsoft setting generation.

- [ ] **Step 5: Route Microsoft adapter and completion through `ProviderConfig`**

```elixir
defp adapter_config("microsoft") do
  adapters = Application.get_env(:manifold_connectors, :adapters, [])
  adapter =
    Keyword.get(adapters, :microsoft) || Manifold.Connectors.Provider.MicrosoftGraph

  with {:ok, %ProviderConfig.Resolved{config: config}} <-
         ProviderConfig.fetch("microsoft") do
    {:ok, adapter, config}
  end
end

defp completion_adapter_config("microsoft", %Consumed{} = consumed) do
  adapters = Application.get_env(:manifold_connectors, :adapters, [])
  adapter =
    Keyword.get(adapters, :microsoft) || Manifold.Connectors.Provider.MicrosoftGraph

  with {:ok, %ProviderConfig.Resolved{} = resolved} <-
         ProviderConfig.fetch("microsoft"),
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
```

Generalize exact matching while retaining only Gmail's bounded legacy
direct-struct compatibility:

```elixir
defp validate_completion_generation(
       %Consumed{
         provider: provider,
         oauth_provider_setting_id: setting_id,
         oauth_provider_setting_lock_version: setting_lock_version
       },
       %ProviderConfig.Resolved{
         provider: provider,
         setting_id: setting_id,
         setting_lock_version: setting_lock_version
       }
     )
     when provider in ["gmail", "microsoft"] and is_binary(setting_id) and
            is_integer(setting_lock_version),
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
       %Consumed{provider: provider},
       %ProviderConfig.Resolved{provider: provider}
     )
     when provider in ["gmail", "microsoft"],
     do: provider_configuration_changed()
```

- [ ] **Step 6: Revalidate both provider generations under the advisory lock**

```elixir
defp lock_and_validate_provider_generation(
       provider,
       {setting_id, setting_lock_version}
     )
     when provider in ["gmail", "microsoft"] and is_binary(setting_id) and
            is_integer(setting_lock_version) do
  with :ok <- ProviderSettings.lock_provider_for_transaction(provider) do
    ProviderSettings.validate_generation_for_transaction(
      provider,
      setting_id,
      setting_lock_version
    )
  end
end

defp lock_and_validate_provider_generation("gmail", {nil, nil}), do: :ok

defp lock_and_validate_provider_generation(provider, {_id, _version})
     when provider in ["gmail", "microsoft"] do
  {:error,
   CoreError.new(
     :permanent,
     :provider_configuration_changed,
     "OAuth provider configuration changed"
   )}
end
```

Do not hold this advisory lock during Microsoft HTTP calls.

- [ ] **Step 7: Resolve Microsoft sync runtime through `ProviderConfig`**

```elixir
defp runtime("microsoft") do
  adapters = Application.get_env(:manifold_connectors, :adapters, [])
  adapter =
    Keyword.get(adapters, :microsoft) || Manifold.Connectors.Provider.MicrosoftGraph

  with {:ok, %ProviderConfig.Resolved{config: config}} <-
         ProviderConfig.fetch("microsoft") do
    {:ok, adapter, config}
  end
end
```

- [ ] **Step 8: Run focused tests to verify GREEN**

Run the command from Step 4.

Expected: both pass with stored credentials and final-persistence fencing.

- [ ] **Step 9: Commit**

```sh
git add \
  apps/manifold_connectors/lib/manifold/connectors.ex \
  apps/manifold_connectors/lib/manifold/connectors/oauth_authorizations.ex \
  apps/manifold_connectors/lib/manifold/connectors/sync.ex \
  apps/manifold_connectors/test/manifold/connectors/microsoft_authorizations_test.exs \
  apps/manifold_connectors/test/manifold/connectors/sync_test.exs
git commit -m "fix(connectors): fence stored Microsoft OAuth credentials"
```

---

### Task 7: Convert integration fixtures and verify immediate picker enablement

**Files:**
- Modify: `apps/manifold_connectors/test/manifold/connectors_test.exs`
- Modify: `apps/manifold_connectors/test/manifold/connectors/submission_method_test.exs`
- Modify: `apps/manifold_connectors/test/manifold/connectors/sync_test.exs`
- Modify: `apps/manifold_outbound/test/manifold/outbound/jobs/submit_outbound_test.exs`
- Modify: `apps/manifold_outbound/test/manifold/outbound/submission_test.exs`
- Modify: `apps/manifold_web/test/manifold_web/oauth_settings_live_test.exs`
- Modify: `apps/manifold_web/test/manifold_web/account_live_test.exs`
- Modify: `apps/manifold_web/test/manifold_web/external_accounts_web_test.exs`

- [ ] **Step 1: Run affected suites to capture fixture failures**

Run sequentially:

```sh
devenv shell -- mix test apps/manifold_connectors/test/manifold/connectors_test.exs
devenv shell -- mix test apps/manifold_connectors/test/manifold/connectors/submission_method_test.exs
devenv shell -- mix test apps/manifold_outbound/test/manifold/outbound/jobs/submit_outbound_test.exs
devenv shell -- mix test apps/manifold_outbound/test/manifold/outbound/submission_test.exs
devenv shell -- mix test apps/manifold_web/test/manifold_web/account_live_test.exs
devenv shell -- mix test apps/manifold_web/test/manifold_web/external_accounts_web_test.exs
```

Expected: Microsoft paths that injected client credentials through application
config fail with `provider_not_configured` or missing setting generation.

- [ ] **Step 2: Use stored Microsoft settings in connector fixtures**

In each connector setup, keep endpoint overrides and test plugs in application
config, remove `:client_id` and `:client_secret`, and add:

```elixir
assert {:ok, _microsoft_setting} =
         Connectors.put_oauth_provider_setting("microsoft", %{
           "client_id" => "microsoft-db-client",
           "client_secret" => "microsoft-db-secret"
         })
```

Apply it in these exact locations:

- `connectors_test.exs`, preserving its `identity_address` test option;
- `submission_method_test.exs`, preserving only endpoint, base URL, tenant, and
  `req_options[:plug]`; and
- the module setup in `sync_test.exs`; in the existing test that temporarily
  replaces the Microsoft `base_url`, reuse that setup-created row and change
  only the application endpoint override.

Assertions that previously expected application credential sentinels must now
expect stored values while still proving credentials are stripped from outbound
submission configuration.

- [ ] **Step 3: Use stored settings in outbound worker fixtures**

In `submit_outbound_test.exs`, make `configure_microsoft_req_test!/0` save a
setting before installing the safe Graph test config:

```elixir
assert {:ok, _setting} =
         Connectors.put_oauth_provider_setting("microsoft", %{
           "client_id" => "worker-db-client",
           "client_secret" => "worker-db-secret"
         })

configured =
  Keyword.put(previous, :microsoft,
    base_url: "https://graph.microsoft.test/v1.0",
    req_options: [plug: {Req.Test, __MODULE__}]
  )
```

In `submission_test.exs`, add a Microsoft setting only to tests that exercise
Microsoft checkout. Preserve its existing Gmail database setting behavior and
avoid global cross-test state.

- [ ] **Step 4: Convert account and controller LiveView fixtures**

In `account_live_test.exs`, replace environment credentials in
`configure_microsoft_provider!/0`:

```elixir
defp configure_microsoft_provider! do
  assert {:ok, _setting} =
           Connectors.put_oauth_provider_setting("microsoft", %{
             "client_id" => "microsoft-ui-client",
             "client_secret" => "microsoft-ui-secret"
           })
end
```

The disabled test must ensure the Microsoft setting row is absent rather than
clearing trusted endpoint configuration.

In `external_accounts_web_test.exs`, save Gmail and Microsoft settings in setup,
return both views where generation assertions require them, and keep only test
endpoints in application config.

- [ ] **Step 5: Add immediate enable/disable LiveView coverage**

Add to `oauth_settings_live_test.exs`:

```elixir
test "saving and removing Microsoft immediately changes receive and send availability", %{
  conn: conn
} do
  {:ok, domain} = Accounts.create_domain(%{name: "microsoft-setting-ui.test"})
  {:ok, account} = Accounts.create_account(domain, %{local_part: "person"})

  {:ok, receive_before, _html} =
    live(conn, ~p"/settings/accounts/#{account.id}/receive_methods/new")
  assert has_element?(receive_before, "#receive-method-microsoft[disabled]")

  {:ok, oauth, _html} = live(conn, ~p"/settings/oauth")

  oauth
  |> form("#oauth-provider-microsoft-form",
    provider: "microsoft",
    oauth_provider_setting: %{
      client_id: "microsoft-ui-client",
      client_secret: "microsoft-ui-secret",
      lock_version: ""
    }
  )
  |> render_submit()

  {:ok, receive_after, _html} =
    live(conn, ~p"/settings/accounts/#{account.id}/receive_methods/new")
  {:ok, send_after, _html} =
    live(conn, ~p"/settings/accounts/#{account.id}/send_methods/new")

  refute has_element?(receive_after, "#receive-method-microsoft[disabled]")
  refute has_element?(send_after, "#send-method-microsoft[disabled]")

  setting = Repo.get_by!(OAuthProviderSetting, provider: "microsoft")

  render_click(oauth, "remove-provider", %{
    "provider" => "microsoft",
    "lock_version" => Integer.to_string(setting.lock_version)
  })

  {:ok, receive_removed, _html} =
    live(conn, ~p"/settings/accounts/#{account.id}/receive_methods/new")
  assert has_element?(receive_removed, "#receive-method-microsoft[disabled]")
end
```

Confirm the existing receive picker ID before finalizing the selector. Do not
change production markup only to satisfy the test.

- [ ] **Step 6: Run affected suites to verify GREEN**

Run the six commands from Step 1, then:

```sh
devenv shell -- mix test \
  apps/manifold_web/test/manifold_web/oauth_settings_live_test.exs
```

Expected: all pass with database-backed Microsoft settings and no restart.

- [ ] **Step 7: Commit**

```sh
git add \
  apps/manifold_connectors/test/manifold/connectors_test.exs \
  apps/manifold_connectors/test/manifold/connectors/submission_method_test.exs \
  apps/manifold_connectors/test/manifold/connectors/sync_test.exs \
  apps/manifold_outbound/test/manifold/outbound/jobs/submit_outbound_test.exs \
  apps/manifold_outbound/test/manifold/outbound/submission_test.exs \
  apps/manifold_web/test/manifold_web/oauth_settings_live_test.exs \
  apps/manifold_web/test/manifold_web/account_live_test.exs \
  apps/manifold_web/test/manifold_web/external_accounts_web_test.exs
git commit -m "test: use stored Microsoft OAuth settings"
```

---

### Task 8: Update operator guidance and repository feature references

**Files:**
- Modify: `README.md`
- Modify: `AGENTS.md`
- Modify: `docs/DESIGN.md`
- Modify: `docs/MILESTONE_6_PLAN.md`
- Modify: `docs/superpowers/specs/2026-08-11-microsoft-365-receive-send-methods-design.md`
- Modify: `docs/superpowers/specs/2026-08-18-oauth-provider-settings-design.md`
- Modify: `.agents/skills/develop/references/oauth-provider-settings.md`
- Modify: `.agents/skills/develop/references/microsoft-365-receive-send-methods.md`
- Modify: `.agents/skills/develop/references/gmail-receive-send-methods.md`

- [ ] **Step 1: Update README and architecture docs**

Document all of the following:

- Google and Microsoft credentials are saved at `/settings/oauth`;
- neither provider client ID/secret is supported through environment variables;
- Microsoft is fixed to `organizations` and work/school identities;
- callback `http://localhost:4290/connectors/microsoft/callback` for local
  development and the HTTPS equivalent in production;
- `MANIFOLD_CONNECTOR_ENCRYPTION_KEY` remains mandatory and stable;
- retained Microsoft environment overrides are authorization URL, token URL,
  and Graph API base URL only;
- save, rotation, and removal take effect immediately and require reconnect;
- the non-rolling cutover drains old workers and queued Microsoft sends; and
- legacy credential variables are not imported or fallback configuration.

Remove `MANIFOLD_MICROSOFT_TENANT` from supported environment lists.

- [ ] **Step 2: Add historical supersession notes**

At the runtime-configuration sections in both older design documents, add:

```markdown
> **Superseded on 2026-08-27:** Microsoft client credentials now use the
> Settings-managed encrypted provider store. The legacy environment variables
> are ignored with no import or fallback; Microsoft remains fixed to the
> `organizations` tenant.
```

Update nearby active statements that contradict the note while retaining the
documents as historical decisions.

- [ ] **Step 3: Update the repository skill references**

In `oauth-provider-settings.md`:

- change catalog status from Gmail-only to Gmail then Microsoft;
- replace the sentence that Microsoft remains environment-backed;
- document that both providers carry UUID/version transaction fences; and
- add Microsoft help, lifecycle, fixture, and verification commands.

In `microsoft-365-receive-send-methods.md`:

- replace environment client configuration with Settings-managed credentials;
- retain work/school-only `organizations`; and
- record the non-rolling cutover and reconnect requirement.

In `gmail-receive-send-methods.md`, remove statements that call Microsoft
environment-backed while preserving Gmail behavior.

In `AGENTS.md`, replace OAuth client credential environment guidance with the
Settings-managed secret rule and retain the connector encryption key warning.

- [ ] **Step 4: Scan for stale operator claims**

```sh
rg -n \
  'MANIFOLD_MICROSOFT_CLIENT_ID|MANIFOLD_MICROSOFT_CLIENT_SECRET|MANIFOLD_MICROSOFT_TENANT|Microsoft.*environment-backed|Microsoft remains environment' \
  README.md AGENTS.md config apps docs .agents \
  --glob '!**/test/**' \
  --glob '!docs/superpowers/plans/2026-08-27-microsoft-oauth-provider-settings.md' \
  --glob '!docs/superpowers/specs/2026-08-27-microsoft-oauth-provider-settings-design.md'
```

Expected: no active operator/runtime claim remains. Historical specs may retain
legacy names only inside explicitly superseded sections.

- [ ] **Step 5: Commit**

```sh
git add \
  README.md \
  AGENTS.md \
  docs/DESIGN.md \
  docs/MILESTONE_6_PLAN.md \
  docs/superpowers/specs/2026-08-11-microsoft-365-receive-send-methods-design.md \
  docs/superpowers/specs/2026-08-18-oauth-provider-settings-design.md \
  .agents/skills/develop/references/oauth-provider-settings.md \
  .agents/skills/develop/references/microsoft-365-receive-send-methods.md \
  .agents/skills/develop/references/gmail-receive-send-methods.md
git commit -m "docs: move Microsoft OAuth credentials to Settings"
```

---

### Task 9: Run scoped verification and record completion evidence

**Files:**
- Modify only if verification exposes an in-scope defect.
- Update: `.agents/skills/develop/references/oauth-provider-settings.md`

- [ ] **Step 1: Format and inspect the complete diff**

```sh
changed_ex=$(git diff --name-only main...HEAD -- '*.ex' '*.exs')
if [ -n "$changed_ex" ]; then
  devenv shell -- mix format $changed_ex
fi

devenv shell -- mix format --check-formatted
git diff --check
git status --short
```

Expected: all commands exit zero and only plan-listed files changed.

- [ ] **Step 2: Compile strictly**

```sh
devenv shell -- mix compile --warnings-as-errors
```

Expected: exit zero with no stale Microsoft resolver clauses or unreachable
generation patterns.

- [ ] **Step 3: Run focused acceptance tests**

```sh
devenv shell -- mix test \
  apps/manifold_data/test/manifold/config_test.exs \
  apps/manifold_connectors/test/manifold/connectors/oauth_provider_catalog_test.exs \
  apps/manifold_connectors/test/manifold/connectors/provider_settings_test.exs \
  apps/manifold_connectors/test/manifold/connectors/provider_config_test.exs \
  apps/manifold_connectors/test/manifold/connectors/oauth_test.exs \
  apps/manifold_connectors/test/manifold/connectors/microsoft_authorizations_test.exs \
  apps/manifold_connectors/test/manifold/connectors/submission_method_test.exs \
  apps/manifold_connectors/test/manifold/connectors/sync_test.exs \
  apps/manifold_connectors/test/manifold/connectors_test.exs \
  apps/manifold_outbound/test/manifold/outbound/jobs/submit_outbound_test.exs \
  apps/manifold_outbound/test/manifold/outbound/submission_test.exs \
  apps/manifold_web/test/manifold_web/oauth_settings_live_test.exs \
  apps/manifold_web/test/manifold_web/account_live_test.exs \
  apps/manifold_web/test/manifold_web/external_accounts_web_test.exs
```

Expected: all focused tests pass.

- [ ] **Step 4: Run affected application suites sequentially**

```sh
devenv shell -- mix test apps/manifold_data/test
devenv shell -- mix test apps/manifold_connectors/test
devenv shell -- mix test apps/manifold_outbound/test
devenv shell -- mix test apps/manifold_web/test
devenv shell -- mix test apps/manifold_mail/test
devenv shell -- mix test apps/manifold_account_lifecycle/test
```

Expected: all six scoped suites pass. If an out-of-scope suite fails, report it
and stop without modifying unrelated files.

- [ ] **Step 5: Verify environment removal and resolver boundaries**

```sh
rg -n 'System\.get_env\("MANIFOLD_MICROSOFT_(CLIENT_ID|CLIENT_SECRET|TENANT)"' \
  config apps

rg -n 'MANIFOLD_MICROSOFT_(CLIENT_ID|CLIENT_SECRET)' \
  README.md AGENTS.md docs/DESIGN.md docs/MILESTONE_6_PLAN.md \
  .agents/skills/develop/references

rg -n 'ProviderConfig\.fetch\("microsoft"\)' \
  apps/manifold_connectors/lib
```

Expected: the first two commands have no matches; the third identifies adapter,
completion, and sync resolver paths.

- [ ] **Step 6: Perform a safe browser smoke when an encryption key is available**

With a stable non-production `MANIFOLD_CONNECTOR_ENCRYPTION_KEY` in the managed
process environment:

1. Open `/settings/oauth`; verify Google then Microsoft card order.
2. Verify Microsoft help shows the exact callback, six scopes, work/school
   limitation, and official links.
3. Save non-production Microsoft credentials; confirm both method pickers enable
   without restarting Manifold.
4. Confirm the secret field stays empty and the secret is absent from HTML,
   logs, and LiveView debug output.
5. Remove the non-production setting; confirm both pickers disable.

If no safe Microsoft client pair is available, use non-secret sentinel values
only for local save/remove availability, remove the row afterward, and record
that external Microsoft OAuth was not exercised. Do not report external staging
as passed.

- [ ] **Step 7: Record exact completion evidence**

Update `.agents/skills/develop/references/oauth-provider-settings.md` with exact
focused and app-suite totals, formatting and compile results, environment scan,
browser status, external staging status, and any in-scope follow-up.

- [ ] **Step 8: Commit verification-only corrections when present**

The completion evidence update is expected to be the only verification edit.
Stage it explicitly:

```sh
git add .agents/skills/develop/references/oauth-provider-settings.md
git diff --cached --check
git commit -m "test: verify Microsoft OAuth provider settings"
```

If verification exposes an implementation defect, return to the owning task,
add a failing regression, fix it, and use that task's file list and commit scope
before repeating Task 9. If only the feature reference changed, use the command
above. If nothing changed, do not create an empty commit.

## Completion criteria

The implementation is complete only when:

1. Microsoft appears after Google at `/settings/oauth` with working help, save,
   rotation, and removal.
2. Both providers use encrypted PostgreSQL credentials and non-nil OAuth setting
   generations.
3. Every Microsoft OAuth, refresh, receive-sync, and send path resolves current
   stored credentials without caching.
4. No production code reads the legacy Microsoft client ID, client secret, or
   tenant environment variables.
5. Microsoft remains fixed to `organizations`; personal Outlook.com is still
   unsupported.
6. Credential changes invalidate in-flight OAuth and reconnect only Microsoft
   dependencies.
7. All available scoped checks pass and unavailable external staging is recorded
   explicitly.
