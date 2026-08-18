# OAuth Provider Settings Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a provider-neutral Settings → OAuth workflow backed by encrypted database credentials, with Gmail configuration and help as the first supported module and no Google client-credential environment fallback.

**Architecture:** `manifold_connectors` owns a code-defined OAuth provider catalog, encrypted provider-setting persistence, lifecycle transitions, and one runtime resolver. Gmail OAuth, refresh, sync, and send paths resolve the current database setting per operation; OAuth transactions fence the setting UUID and lock version. `manifold_web` renders provider cards and catalog help pages without ever receiving decrypted secrets.

**Tech Stack:** Elixir 1.18, Phoenix LiveView, Ecto/PostgreSQL, AES-256-GCM through `Manifold.Connectors.Crypto`, phoenix_duskmoon, ExUnit

---

## File Map

### Data and connector ownership

- Create `apps/manifold_data/priv/repo/migrations/20260818000100_add_oauth_provider_settings.exs` — generic provider-setting table and OAuth transaction generation snapshot.
- Create `apps/manifold_connectors/lib/manifold/connectors/schema/oauth_provider_setting.ex` — persisted setting plus redacted virtual secret input.
- Modify `apps/manifold_connectors/lib/manifold/connectors/schema/oauth_transaction.ex` — setting UUID/version snapshot fields.
- Create `apps/manifold_connectors/lib/manifold/connectors/oauth_provider_catalog.ex` — trusted provider lookup and enumeration.
- Create `apps/manifold_connectors/lib/manifold/connectors/oauth_provider/gmail.ex` — Gmail metadata, endpoints, scopes, callback, and help content.
- Create `apps/manifold_connectors/lib/manifold/connectors/provider_settings.ex` — encrypted CRUD, locking, lifecycle effects, and safe view models.
- Create `apps/manifold_connectors/lib/manifold/connectors/provider_config.ex` — one runtime provider configuration resolver.
- Modify `apps/manifold_connectors/lib/manifold/connectors.ex` — public settings boundary and all Gmail adapter/send configuration calls.
- Modify `apps/manifold_connectors/lib/manifold/connectors/oauth.ex` — resolver use and setting-generation fencing.
- Modify `apps/manifold_connectors/lib/manifold/connectors/sync.ex` — resolver use for Gmail synchronization.

### Runtime and web

- Modify `config/runtime.exs` — remove Google client ID/secret environment loading; preserve static endpoint overrides and Microsoft behavior.
- Modify `apps/manifold_data/test/manifold/config_test.exs` — prove legacy Google credential variables are ignored.
- Modify `apps/manifold_web/lib/manifold_web/router.ex` — OAuth settings and help routes.
- Modify `apps/manifold_web/lib/manifold_web/components/settings_components.ex` — OAuth navigation item.
- Modify `apps/manifold_web/lib/manifold_web/hooks/settings_path.ex` — OAuth current-section mapping.
- Create `apps/manifold_web/lib/manifold_web/live/settings_live/oauth.ex` — provider list, safe save/replace/remove form.
- Create `apps/manifold_web/lib/manifold_web/live/settings_live/oauth_help.ex` — provider-catalog help renderer.
- Modify `apps/manifold_web/test/manifold_web/settings_live_test.exs` — navigation and current-section coverage.
- Create `apps/manifold_web/test/manifold_web/oauth_settings_live_test.exs` — secret-safe form and help behavior.

### Tests and documentation

- Create `apps/manifold_connectors/test/manifold/connectors/oauth_provider_catalog_test.exs`.
- Create `apps/manifold_connectors/test/manifold/connectors/provider_settings_test.exs`.
- Create `apps/manifold_connectors/test/manifold/connectors/provider_config_test.exs`.
- Modify `apps/manifold_connectors/test/manifold/connectors/oauth_test.exs`.
- Modify `apps/manifold_connectors/test/manifold/connectors/gmail_authorizations_test.exs`.
- Modify `apps/manifold_connectors/test/manifold/connectors/sync_test.exs`.
- Modify `apps/manifold_connectors/test/manifold/connectors_test.exs`.
- Modify `apps/manifold_web/test/manifold_web/external_accounts_web_test.exs`.
- Modify `apps/manifold_web/test/manifold_web/account_live_test.exs`.
- Modify `README.md`, `docs/DESIGN.md`, and `docs/MILESTONE_6_PLAN.md`.
- Modify `.agents/skills/develop/references/gmail-receive-send-methods.md`.
- Create `.agents/skills/develop/references/oauth-provider-settings.md`.

---

### Task 1: Add the generic provider-setting schema and catalog

**Files:**
- Create: `apps/manifold_data/priv/repo/migrations/20260818000100_add_oauth_provider_settings.exs`
- Create: `apps/manifold_connectors/lib/manifold/connectors/schema/oauth_provider_setting.ex`
- Modify: `apps/manifold_connectors/lib/manifold/connectors/schema/oauth_transaction.ex`
- Create: `apps/manifold_connectors/lib/manifold/connectors/oauth_provider_catalog.ex`
- Create: `apps/manifold_connectors/lib/manifold/connectors/oauth_provider/gmail.ex`
- Create: `apps/manifold_connectors/test/manifold/connectors/oauth_provider_catalog_test.exs`
- Create: `apps/manifold_connectors/test/manifold/connectors/schema/oauth_provider_setting_test.exs`

- [ ] **Step 1: Write failing catalog and schema tests**

```elixir
test "catalog exposes Gmail as the first supported settings provider" do
  assert [%{key: "gmail", name: "Gmail"} = gmail] = OAuthProviderCatalog.list()
  assert gmail.callback_path == "/connectors/gmail/callback"
  assert gmail.scopes == [
           "email",
           "https://www.googleapis.com/auth/gmail.readonly",
           "https://www.googleapis.com/auth/gmail.send",
           "openid"
         ]
  assert {:error, %Error{reason: :unsupported_provider}} =
           OAuthProviderCatalog.fetch("unknown")
end

test "provider setting redacts secret fields" do
  setting = %OAuthProviderSetting{
    id: Ecto.UUID.generate(),
    provider: "gmail",
    client_id: "client-id",
    client_secret: "browser-secret",
    client_secret_ciphertext: <<1, 2, 3>>
  }

  inspected = inspect(setting)
  refute inspected =~ "browser-secret"
  refute inspected =~ inspect(<<1, 2, 3>>)
end
```

- [ ] **Step 2: Run the tests and verify RED**

```sh
devenv shell -- mix test \
  apps/manifold_connectors/test/manifold/connectors/oauth_provider_catalog_test.exs \
  apps/manifold_connectors/test/manifold/connectors/schema/oauth_provider_setting_test.exs
```

Expected: compilation fails because the catalog and setting schema do not exist.

- [ ] **Step 3: Add the migration**

Create the provider table and generation snapshot fields:

```elixir
defmodule Manifold.Repo.Migrations.AddOAuthProviderSettings do
  use Ecto.Migration

  def up do
    create table(:connector_oauth_provider_settings, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:provider, :text, null: false)
      add(:client_id, :text, null: false)
      add(:client_secret_ciphertext, :binary, null: false)
      add(:key_version, :integer, null: false, default: 1)
      add(:lock_version, :integer, null: false, default: 1)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:connector_oauth_provider_settings, [:provider]))

    create(
      constraint(:connector_oauth_provider_settings, :oauth_provider_settings_provider_present,
        check: "length(btrim(provider)) > 0"
      )
    )

    create(
      constraint(:connector_oauth_provider_settings, :oauth_provider_settings_client_id_present,
        check: "length(btrim(client_id)) > 0"
      )
    )

    alter table(:connector_oauth_transactions) do
      add(:oauth_provider_setting_id, :binary_id)
      add(:oauth_provider_setting_lock_version, :integer)
    end

    create(
      constraint(:connector_oauth_transactions, :oauth_transaction_setting_generation_valid,
        check:
          "(oauth_provider_setting_id IS NULL) = " <>
            "(oauth_provider_setting_lock_version IS NULL)"
      )
    )
  end

  def down do
    %{rows: [[settings_count]]} =
      repo().query!("SELECT COUNT(*) FROM connector_oauth_provider_settings", [])

    %{rows: [[transaction_count]]} =
      repo().query!(
        "SELECT COUNT(*) FROM connector_oauth_transactions " <>
          "WHERE oauth_provider_setting_id IS NOT NULL",
        []
      )

    if settings_count > 0 or transaction_count > 0 do
      raise "cannot roll back OAuth provider settings while settings or fenced transactions exist"
    end

    drop(
      constraint(
        :connector_oauth_transactions,
        :oauth_transaction_setting_generation_valid
      )
    )

    alter table(:connector_oauth_transactions) do
      remove(:oauth_provider_setting_lock_version)
      remove(:oauth_provider_setting_id)
    end

    drop(table(:connector_oauth_provider_settings))
  end
end
```

- [ ] **Step 4: Add the schema and catalog modules**

The schema must mark secret-bearing fields `redact: true` and accept the virtual
secret only at the mutation boundary:

```elixir
schema "connector_oauth_provider_settings" do
  field(:provider, :string)
  field(:client_id, :string)
  field(:client_secret_ciphertext, :binary, redact: true)
  field(:client_secret, :string, virtual: true, redact: true)
  field(:key_version, :integer, default: 1)
  field(:lock_version, :integer, default: 1)
  timestamps(type: :utc_datetime_usec)
end
```

`OAuthProviderCatalog.list/0` returns provider definitions in stable display order;
`fetch/1` returns `{:ok, definition}` or a permanent `:unsupported_provider` error.
The Gmail definition contains only trusted static metadata and official help links.

- [ ] **Step 5: Update `OAuthTransaction` fields and changeset**

Add both fields and validate that they are either both present or both absent:

```elixir
field(:oauth_provider_setting_id, :binary_id)
field(:oauth_provider_setting_lock_version, :integer)

validate_change(changeset, :oauth_provider_setting_id, fn _, setting_id ->
  if Ecto.UUID.cast(setting_id) == :error,
    do: [oauth_provider_setting_id: "is invalid"],
    else: []
end)
```

- [ ] **Step 6: Run migration and focused tests**

```sh
devenv shell -- mix ecto.migrate
devenv shell -- mix test \
  apps/manifold_connectors/test/manifold/connectors/oauth_provider_catalog_test.exs \
  apps/manifold_connectors/test/manifold/connectors/schema/oauth_provider_setting_test.exs
```

Expected: migration succeeds; catalog and schema tests pass.

- [ ] **Step 7: Commit**

```sh
git add apps/manifold_data/priv/repo/migrations/20260818000100_add_oauth_provider_settings.exs \
  apps/manifold_connectors/lib/manifold/connectors/schema/oauth_provider_setting.ex \
  apps/manifold_connectors/lib/manifold/connectors/schema/oauth_transaction.ex \
  apps/manifold_connectors/lib/manifold/connectors/oauth_provider_catalog.ex \
  apps/manifold_connectors/lib/manifold/connectors/oauth_provider/gmail.ex \
  apps/manifold_connectors/test/manifold/connectors/oauth_provider_catalog_test.exs \
  apps/manifold_connectors/test/manifold/connectors/schema/oauth_provider_setting_test.exs
git commit -m "feat(connectors): add OAuth provider settings catalog"
```

---

### Task 2: Implement encrypted provider-setting mutations and lifecycle effects

**Files:**
- Create: `apps/manifold_connectors/lib/manifold/connectors/provider_settings.ex`
- Modify: `apps/manifold_connectors/lib/manifold/connectors.ex`
- Create: `apps/manifold_connectors/test/manifold/connectors/provider_settings_test.exs`

- [ ] **Step 1: Write failing persistence and secret-safety tests**

Cover create, blank-secret retention, rotation, client-ID replacement, removal,
corrupt ciphertext, and unsupported provider. The central assertion is:

```elixir
assert {:ok, view} =
         Connectors.put_oauth_provider_setting("gmail", %{
           "client_id" => "google-client",
           "client_secret" => "google-secret"
         })

row = Repo.get_by!(OAuthProviderSetting, provider: "gmail")
assert row.client_id == "google-client"
refute row.client_secret_ciphertext =~ "google-secret"
refute inspect(row) =~ "google-secret"
assert view == %{
         provider: "gmail",
         client_id: "google-client",
         client_secret_configured?: true,
         status: :configured,
         lock_version: row.lock_version
       }

assert {:ok, "google-secret"} =
         Crypto.decrypt(
           row.client_secret_ciphertext,
           "oauth_provider_setting:#{row.id}:client_secret"
         )
```

Add a blank-secret test that records the original ciphertext, saves the same
client ID with `"client_secret" => ""`, and asserts byte-identical ciphertext.
Add a changed-ID blank-secret test expecting a changeset error on
`:client_secret`.

- [ ] **Step 2: Write failing lifecycle tests**

Create Gmail authorization, receive method, send method, and an unconsumed OAuth
transaction. Assert initial save with legacy grants, secret rotation, client-ID
change, and removal each produce:

```elixir
assert Repo.get!(OAuthAuthorization, authorization.id).status == "reconnect_required"

receive = Repo.get!(ReceiveMethod, receive.id)
assert receive.status == "reconnect_required"
refute receive.enabled
refute receive.sync_enabled

send_method = Repo.get!(SendMethod, send_method.id)
assert send_method.status == "reconnect_required"
refute send_method.enabled
```

The transaction remains one-time state but its setting generation no longer
matches; Task 4 will make callback consumption reject it. Assert unrelated
Microsoft rows remain unchanged.

- [ ] **Step 3: Run tests and verify RED**

```sh
devenv shell -- mix test \
  apps/manifold_connectors/test/manifold/connectors/provider_settings_test.exs
```

Expected: undefined public setting APIs.

- [ ] **Step 4: Implement provider setting transactions**

Expose this public boundary from `Manifold.Connectors`:

```elixir
def list_oauth_provider_settings,
  do: ProviderSettings.list()

def get_oauth_provider_setting(provider),
  do: ProviderSettings.get(provider)

def change_oauth_provider_setting(provider, attrs \\ %{}),
  do: ProviderSettings.change(provider, attrs)

def put_oauth_provider_setting(provider, attrs, opts \\ []),
  do: ProviderSettings.put(provider, attrs, opts)

def remove_oauth_provider_setting(provider, opts \\ []),
  do: ProviderSettings.remove(provider, opts)
```

`ProviderSettings.put/3` must:

1. validate catalog membership before opening a transaction;
2. lock the setting row by provider;
3. enforce `expected_lock_version` when supplied;
4. require a secret for create or client-ID change;
5. generate an ID before encrypting a new row;
6. preserve ciphertext only for unchanged ID plus blank secret;
7. increment `lock_version` on actual credential changes;
8. lock dependent authorization/method rows in stable ID order;
9. mark Gmail dependencies `reconnect_required` and disabled;
10. return only the safe view map.

Use fixed AAD:

```elixir
defp secret_context(setting_id),
  do: "oauth_provider_setting:#{setting_id}:client_secret"
```

`remove/2` applies the same scoped lifecycle transition, then deletes only that
provider row. Never erase authorization token ciphertext.

- [ ] **Step 5: Implement safe reads and corruption status**

`get/1` returns:

```elixir
{:ok,
 %{
   provider: setting.provider,
   client_id: setting.client_id,
   client_secret_configured?: true,
   status: :configured,
   lock_version: setting.lock_version
 }}
```

Missing rows return `{:ok, %{provider: provider, status: :not_configured, ...}}`.
An undecryptable row returns the same public shape with
`status: :configuration_error`; it never includes the crypto error details.

- [ ] **Step 6: Run tests and verify GREEN**

```sh
devenv shell -- mix test \
  apps/manifold_connectors/test/manifold/connectors/provider_settings_test.exs
```

Expected: all provider-setting tests pass.

- [ ] **Step 7: Commit**

```sh
git add apps/manifold_connectors/lib/manifold/connectors/provider_settings.ex \
  apps/manifold_connectors/lib/manifold/connectors.ex \
  apps/manifold_connectors/test/manifold/connectors/provider_settings_test.exs
git commit -m "feat(connectors): manage encrypted OAuth provider settings"
```

---

### Task 3: Add the runtime resolver and remove Google credential environment configuration

**Files:**
- Create: `apps/manifold_connectors/lib/manifold/connectors/provider_config.ex`
- Modify: `apps/manifold_connectors/lib/manifold/connectors.ex`
- Modify: `config/runtime.exs`
- Modify: `apps/manifold_data/test/manifold/config_test.exs`
- Create: `apps/manifold_connectors/test/manifold/connectors/provider_config_test.exs`

- [ ] **Step 1: Write failing resolver tests**

```elixir
test "Gmail resolver combines database credentials with trusted endpoints" do
  put_gmail_setting!("db-client", "db-secret")

  assert {:ok, %ProviderConfig.Resolved{} = resolved} = ProviderConfig.fetch("gmail")
  config = resolved.config
  assert config[:client_id] == "db-client"
  assert config[:client_secret] == "db-secret"
  assert config[:authorization_url] == "https://accounts.google.com/o/oauth2/v2/auth"
  assert config[:token_url] == "https://oauth2.googleapis.com/token"
  assert config[:base_url] == "https://gmail.googleapis.com"
  assert is_binary(resolved.setting_id)
  assert is_integer(resolved.setting_lock_version)
end

test "legacy Gmail environment-style application credentials are ignored" do
  Application.put_env(:manifold_connectors, :providers,
    gmail: [
      client_id: "legacy-client",
      client_secret: "legacy-secret",
      authorization_url: "https://accounts.google.com/o/oauth2/v2/auth"
    ]
  )

  assert {:error, %Error{reason: :provider_not_configured}} =
           ProviderConfig.fetch("gmail")
end
```

Also assert Microsoft continues using its current application configuration.

- [ ] **Step 2: Run tests and verify RED**

```sh
devenv shell -- mix test \
  apps/manifold_connectors/test/manifold/connectors/provider_config_test.exs \
  apps/manifold_data/test/manifold/config_test.exs
```

Expected: resolver is undefined and runtime config tests still expect legacy vars.

- [ ] **Step 3: Implement `ProviderConfig.fetch/1`**

Define a stable resolver result used by every later task:

```elixir
defmodule Resolved do
  @enforce_keys [:provider, :config]
  defstruct [:provider, :config, :setting_id, :setting_lock_version]
end
```

For catalog-backed providers, read/decrypt the database row and merge only its
client credentials into trusted static configuration:

```elixir
def fetch("gmail") do
  with {:ok, definition} <- OAuthProviderCatalog.fetch("gmail"),
       {:ok, credentials} <- ProviderSettings.runtime_credentials("gmail") do
    config =
      definition.runtime_config
      |> Keyword.put(:client_id, credentials.client_id)
      |> Keyword.put(:client_secret, credentials.client_secret)

    {:ok,
     %Resolved{
       provider: "gmail",
       config: config,
       setting_id: credentials.setting_id,
       setting_lock_version: credentials.setting_lock_version
     }}
  end
end
```

For Microsoft, preserve the current application-config lookup until its own
catalog migration, returning a `Resolved` value with both setting-generation
fields `nil`. Reject unknown providers.

- [ ] **Step 4: Make configured-provider discovery use the resolver**

Replace direct `Application.get_env` checks:

```elixir
def configured_providers do
  ["gmail", "microsoft"]
  |> Enum.filter(&match?({:ok, %ProviderConfig.Resolved{}}, ProviderConfig.fetch(&1)))
end
```

Add immediate save/remove assertions to the resolver test.

- [ ] **Step 5: Remove old Google credential env loading**

Delete reads of `MANIFOLD_GMAIL_CLIENT_ID` and
`MANIFOLD_GMAIL_CLIENT_SECRET`. Keep endpoint validation/overrides as static
Gmail runtime configuration and keep Microsoft credentials unchanged.

Update `config_test.exs` to set both legacy Google variables and assert the
evaluated Gmail application config contains endpoints but no `:client_id` or
`:client_secret`.

- [ ] **Step 6: Run focused tests**

```sh
devenv shell -- mix test \
  apps/manifold_connectors/test/manifold/connectors/provider_config_test.exs \
  apps/manifold_data/test/manifold/config_test.exs
```

Expected: database resolver tests pass; legacy Google vars are ignored;
Microsoft tests remain green.

- [ ] **Step 7: Commit**

```sh
git add apps/manifold_connectors/lib/manifold/connectors/provider_config.ex \
  apps/manifold_connectors/lib/manifold/connectors.ex \
  apps/manifold_connectors/test/manifold/connectors/provider_config_test.exs \
  apps/manifold_data/test/manifold/config_test.exs config/runtime.exs
git commit -m "feat(connectors): resolve OAuth settings from database"
```

---

### Task 4: Fence OAuth transactions to the provider-setting generation

**Files:**
- Modify: `apps/manifold_connectors/lib/manifold/connectors/oauth.ex`
- Modify: `apps/manifold_connectors/test/manifold/connectors/oauth_test.exs`
- Modify: `apps/manifold_web/lib/manifold_web/controllers/connector_oauth_controller.ex`
- Modify: `apps/manifold_web/test/manifold_web/external_accounts_web_test.exs`

- [ ] **Step 1: Write failing generation-fence tests**

Start Gmail OAuth, inspect the persisted transaction, rotate the secret, then
consume the original state:

```elixir
assert {:ok, authorization} =
         OAuth.start("gmail", mailbox.id, redirect_uri, purpose: :receive)

transaction = Repo.get_by!(OAuthTransaction, provider: "gmail")
setting = Repo.get_by!(OAuthProviderSetting, provider: "gmail")
assert transaction.oauth_provider_setting_id == setting.id
assert transaction.oauth_provider_setting_lock_version == setting.lock_version

assert {:ok, _view} =
         Connectors.put_oauth_provider_setting("gmail", %{
           "client_id" => setting.client_id,
           "client_secret" => "rotated-secret"
         })

assert {:error, %Error{reason: :provider_configuration_changed}} =
         OAuth.consume("gmail", authorization.state, redirect_uri)
```

Repeat with remove then recreate; the new UUID must still reject the old state.
Assert the state cannot be consumed a second time.

- [ ] **Step 2: Run tests and verify RED**

```sh
devenv shell -- mix test \
  apps/manifold_connectors/test/manifold/connectors/oauth_test.exs
```

Expected: transactions do not snapshot or compare provider setting generation.

- [ ] **Step 3: Snapshot the resolver generation on start**

Use the resolver metadata defined in Task 3 alongside runtime credentials:

```elixir
{:ok,
 %{
  config: config,
   setting_id: setting.id,
   setting_lock_version: setting.lock_version
 }}
```

Persist the UUID and version in `OAuthTransaction` with the encrypted verifier.
Microsoft keeps both fields `nil` until migrated to catalog settings.

- [ ] **Step 4: Compare the generation during consume**

While the OAuth transaction row is locked, fetch the current setting generation.
If UUID/version differ or the setting is absent, atomically consume the state and
return a generic permanent `:provider_configuration_changed` error. Never attempt
code exchange with a different configuration.

- [ ] **Step 5: Keep controller errors generic**

The callback continues to show the existing public invalid/expired authorization
copy. Do not reveal whether the setting was removed, rotated, corrupt, or missing.

- [ ] **Step 6: Run OAuth and web callback tests**

```sh
devenv shell -- mix test \
  apps/manifold_connectors/test/manifold/connectors/oauth_test.exs \
  apps/manifold_web/test/manifold_web/external_accounts_web_test.exs
```

Expected: generation-fence and existing one-time state tests pass.

- [ ] **Step 7: Commit**

```sh
git add apps/manifold_connectors/lib/manifold/connectors/oauth.ex \
  apps/manifold_connectors/test/manifold/connectors/oauth_test.exs \
  apps/manifold_web/lib/manifold_web/controllers/connector_oauth_controller.ex \
  apps/manifold_web/test/manifold_web/external_accounts_web_test.exs
git commit -m "fix(connectors): fence OAuth client generations"
```

---

### Task 5: Route every Gmail operation through the database resolver

**Files:**
- Modify: `apps/manifold_connectors/lib/manifold/connectors.ex`
- Modify: `apps/manifold_connectors/lib/manifold/connectors/oauth.ex`
- Modify: `apps/manifold_connectors/lib/manifold/connectors/sync.ex`
- Modify: `apps/manifold_connectors/test/manifold/connectors_test.exs`
- Modify: `apps/manifold_connectors/test/manifold/connectors/gmail_authorizations_test.exs`
- Modify: `apps/manifold_connectors/test/manifold/connectors/sync_test.exs`
- Modify: `apps/manifold_web/test/manifold_web/account_live_test.exs`
- Modify: `apps/manifold_web/test/manifold_web/external_accounts_web_test.exs`

- [ ] **Step 1: Convert Gmail fixtures to database settings**

Replace Gmail-specific `Application.put_env(:manifold_connectors, :providers, ...)`
fixtures with:

```elixir
assert {:ok, _setting} =
         Connectors.put_oauth_provider_setting("gmail", %{
           "client_id" => "gmail-test-client",
           "client_secret" => "gmail-test-secret"
         })
```

Keep Microsoft application-config fixtures unchanged.

- [ ] **Step 2: Add failing integration assertions**

Use fake Gmail adapters that send their received config to the test process.
Assert database credentials reach:

- authorization-code exchange;
- token refresh;
- initial receive discovery and sync;
- Gmail send-method checkout/submission.

After removing the setting, assert each path returns
`:provider_not_configured` without calling the fake provider.

- [ ] **Step 3: Run focused tests and verify RED**

```sh
devenv shell -- mix test \
  apps/manifold_connectors/test/manifold/connectors_test.exs \
  apps/manifold_connectors/test/manifold/connectors/gmail_authorizations_test.exs \
  apps/manifold_connectors/test/manifold/connectors/sync_test.exs \
  apps/manifold_web/test/manifold_web/account_live_test.exs \
  apps/manifold_web/test/manifold_web/external_accounts_web_test.exs
```

Expected: at least one direct application-config Gmail path bypasses the resolver.

- [ ] **Step 4: Replace all direct Gmail config reads**

Use `ProviderConfig.fetch/1` in:

- OAuth provider configuration;
- `adapter_config/1` during completion;
- access-token refresh options;
- sync adapter configuration;
- `oauth_submission_config/1` during send checkout.

Do not decrypt the provider setting directly in callers. Do not change Microsoft
behavior.

- [ ] **Step 5: Add a stale-read scan**

```sh
rg -n 'MANIFOLD_GMAIL_CLIENT_(ID|SECRET)|providers.*gmail|Keyword.get\(providers.*gmail' \
  config apps README.md docs .agents/skills/develop/references
```

Expected at this stage: only documentation scheduled for Task 8 and tests proving
legacy variables are ignored; no Gmail runtime consumer reads application
credentials directly.

- [ ] **Step 6: Run focused tests and verify GREEN**

```sh
devenv shell -- mix test \
  apps/manifold_connectors/test/manifold/connectors_test.exs \
  apps/manifold_connectors/test/manifold/connectors/gmail_authorizations_test.exs \
  apps/manifold_connectors/test/manifold/connectors/sync_test.exs \
  apps/manifold_web/test/manifold_web/account_live_test.exs \
  apps/manifold_web/test/manifold_web/external_accounts_web_test.exs
```

Expected: all resolver integration and existing Gmail tests pass.

- [ ] **Step 7: Commit**

```sh
git add apps/manifold_connectors/lib/manifold/connectors.ex \
  apps/manifold_connectors/lib/manifold/connectors/oauth.ex \
  apps/manifold_connectors/lib/manifold/connectors/sync.ex \
  apps/manifold_connectors/test/manifold/connectors_test.exs \
  apps/manifold_connectors/test/manifold/connectors/gmail_authorizations_test.exs \
  apps/manifold_connectors/test/manifold/connectors/sync_test.exs \
  apps/manifold_web/test/manifold_web/account_live_test.exs \
  apps/manifold_web/test/manifold_web/external_accounts_web_test.exs
git commit -m "refactor(connectors): use stored Gmail OAuth settings"
```

---

### Task 6: Add Settings → OAuth navigation and secret-safe Gmail form

**Files:**
- Modify: `apps/manifold_web/lib/manifold_web/router.ex`
- Modify: `apps/manifold_web/lib/manifold_web/components/settings_components.ex`
- Modify: `apps/manifold_web/lib/manifold_web/hooks/settings_path.ex`
- Create: `apps/manifold_web/lib/manifold_web/live/settings_live/oauth.ex`
- Create: `apps/manifold_web/lib/manifold_web/live/settings_live/oauth_help.ex`
- Modify: `apps/manifold_web/test/manifold_web/settings_live_test.exs`
- Create: `apps/manifold_web/test/manifold_web/oauth_settings_live_test.exs`

- [ ] **Step 1: Read the DuskMoon UI guidance before HEEX work**

Read completely:

```text
/home/gao/.agents/skills/phoenix-duskmoon-design/SKILL.md
/home/gao/.agents/skills/phoenix-duskmoon-ui/SKILL.md
```

Use existing Settings layout classes and DuskMoon components. Do not add hardcoded
palette colors.

- [ ] **Step 2: Write failing navigation and initial form tests**

```elixir
test "OAuth settings renders Gmail from the provider catalog", %{conn: conn} do
  {:ok, _view, html} = live(conn, ~p"/settings/oauth")
  assert html =~ ~s(data-current="oauth")
  assert html =~ "Google OAuth"
  assert html =~ "Not configured"
  assert html =~ ~p"/settings/oauth/gmail/help"
  refute html =~ "MANIFOLD_GMAIL_CLIENT_SECRET"
end
```

Update every existing nav assertion to include `/settings/oauth`.

- [ ] **Step 3: Write failing save and secret non-rendering tests**

Submit `#oauth-provider-gmail-form` with a distinctive secret. Assert:

```elixir
view
|> form("#oauth-provider-gmail-form",
  oauth_provider_setting: %{
    client_id: "google-client",
    client_secret: "never-render-this-secret",
    lock_version: ""
  }
)
|> render_submit()

html = render(view)
assert html =~ "Configured"
assert html =~ "google-client"
refute html =~ "never-render-this-secret"
assert Repo.get_by!(OAuthProviderSetting, provider: "gmail")
```

Add tests for blank-secret retention, changed-ID secret requirement, rotated
secret, stale lock version, corrupt setting status, and confirmed removal.

- [ ] **Step 4: Run web tests and verify RED**

```sh
devenv shell -- mix test \
  apps/manifold_web/test/manifold_web/settings_live_test.exs \
  apps/manifold_web/test/manifold_web/oauth_settings_live_test.exs
```

Expected: route/module/nav do not exist.

- [ ] **Step 5: Add routes, nav, and section hook**

```elixir
live("/settings/oauth", SettingsLive.OAuth, :index)
live("/settings/oauth/:provider/help", SettingsLive.OAuthHelp, :show)
```

Add `:oauth` to the settings component attribute values, render an OAuth nav link
with a key icon, and map `/settings/oauth` plus children to `:oauth` before the
fallback clause.

Create a minimal `OAuthHelp` LiveView in this task that validates the provider
through `OAuthProviderCatalog.fetch/1`, renders the provider name and callback,
and safely redirects unsupported providers. Task 7 adds the full catalog-driven
instructions and official links. This keeps the committed route compilable and
the help link valid after Task 6.

- [ ] **Step 6: Implement the OAuth LiveView**

On mount, assign only catalog definitions and safe provider-setting views. The
save handler must destructure the secret locally and clear it from form state:

```elixir
def handle_event("save-provider", %{"provider" => provider, "oauth_provider_setting" => params}, socket) do
  result = Connectors.put_oauth_provider_setting(provider, params,
    expected_lock_version: parse_lock_version(params["lock_version"])
  )

  case result do
    {:ok, _setting} ->
      {:noreply,
       socket
       |> put_flash(:info, "Google OAuth configuration saved.")
       |> reload_provider(provider)}

    {:error, %Ecto.Changeset{} = changeset} ->
      safe_params = Map.put(params, "client_secret", "")
      {:noreply, assign_provider_form(socket, provider, changeset, safe_params)}

    {:error, _error} ->
      {:noreply,
       socket
       |> put_flash(:error, "OAuth configuration could not be saved.")
       |> reload_provider(provider)}
  end
end
```

Do not use `phx-change`. Render the secret input with `value=""` and autocomplete
`new-password`. Removal uses a separate `remove-provider` event and `data-confirm`
warning. Unsupported provider events return a generic error without atom creation.

- [ ] **Step 7: Run web tests and verify GREEN**

```sh
devenv shell -- mix test \
  apps/manifold_web/test/manifold_web/settings_live_test.exs \
  apps/manifold_web/test/manifold_web/oauth_settings_live_test.exs
```

Expected: navigation, save/replace/remove, and secret-safety tests pass.

- [ ] **Step 8: Build assets and commit**

```sh
devenv shell -- mix assets.build
git add apps/manifold_web/lib/manifold_web/router.ex \
  apps/manifold_web/lib/manifold_web/components/settings_components.ex \
  apps/manifold_web/lib/manifold_web/hooks/settings_path.ex \
  apps/manifold_web/lib/manifold_web/live/settings_live/oauth.ex \
  apps/manifold_web/lib/manifold_web/live/settings_live/oauth_help.ex \
  apps/manifold_web/test/manifold_web/settings_live_test.exs \
  apps/manifold_web/test/manifold_web/oauth_settings_live_test.exs
git commit -m "feat(web): add OAuth provider settings"
```

---

### Task 7: Add catalog-driven provider help pages

**Files:**
- Modify: `apps/manifold_web/lib/manifold_web/live/settings_live/oauth_help.ex`
- Modify: `apps/manifold_web/test/manifold_web/oauth_settings_live_test.exs`
- Modify: `apps/manifold_connectors/lib/manifold/connectors/oauth_provider/gmail.ex`
- Modify: `apps/manifold_connectors/test/manifold/connectors/oauth_provider_catalog_test.exs`

- [ ] **Step 1: Write failing Gmail help tests**

```elixir
test "Gmail help shows exact callback, scopes, checklist, and official links", %{conn: conn} do
  {:ok, _view, html} = live(conn, ~p"/settings/oauth/gmail/help")

  assert html =~ "Set up Google OAuth"
  assert html =~ "http://localhost:4290/connectors/gmail/callback"
  assert html =~ "https://www.googleapis.com/auth/gmail.readonly"
  assert html =~ "https://www.googleapis.com/auth/gmail.send"
  assert html =~ "Testing-mode authorizations can expire after seven days"
  assert html =~ "https://support.google.com/cloud/answer/15549945"
  assert html =~ ~p"/settings/oauth"
end

test "unsupported provider help is not exposed", %{conn: conn} do
  assert {:error, {:live_redirect, %{to: "/settings/oauth"}}} =
           live(conn, "/settings/oauth/unknown/help")
end
```

- [ ] **Step 2: Run tests and verify RED**

```sh
devenv shell -- mix test \
  apps/manifold_web/test/manifold_web/oauth_settings_live_test.exs
```

Expected: help LiveView is missing.

- [ ] **Step 3: Put structured help data in the Gmail catalog module**

Use data, not provider-specific HEEX branching:

```elixir
help: %{
  title: "Set up Google OAuth",
  steps: [
    "Create or select a Google Cloud project.",
    "Enable the Gmail API.",
    "Configure OAuth branding and audience.",
    "Add Manifold's required scopes.",
    "Add test users when the app is in Testing mode.",
    "Create a Web application OAuth client.",
    "Register the exact callback URI shown below.",
    "Save the client ID and secret in Manifold."
  ],
  links: [
    {"Manage app audience", "https://support.google.com/cloud/answer/15549945?hl=en"},
    {"OAuth verification", "https://support.google.com/cloud/answer/13463073?hl=en"},
    {"Request minimum scopes", "https://support.google.com/cloud/answer/13807380?hl=en"}
  ]
}
```

- [ ] **Step 4: Implement the generic help renderer**

Fetch only through `OAuthProviderCatalog.fetch/1`, derive the callback with
`url(~p"/connectors/#{provider}/callback")`, and render ordered steps, scopes,
testing note, official links with safe external-link attributes, copyable callback,
and back navigation. Redirect unsupported keys to `/settings/oauth` with a generic
flash.

- [ ] **Step 5: Run help/catalog tests**

```sh
devenv shell -- mix test \
  apps/manifold_connectors/test/manifold/connectors/oauth_provider_catalog_test.exs \
  apps/manifold_web/test/manifold_web/oauth_settings_live_test.exs
```

Expected: all help and catalog tests pass.

- [ ] **Step 6: Commit**

```sh
git add apps/manifold_connectors/lib/manifold/connectors/oauth_provider/gmail.ex \
  apps/manifold_connectors/test/manifold/connectors/oauth_provider_catalog_test.exs \
  apps/manifold_web/lib/manifold_web/live/settings_live/oauth_help.ex \
  apps/manifold_web/test/manifold_web/oauth_settings_live_test.exs
git commit -m "feat(web): add OAuth provider setup help"
```

---

### Task 8: Update operator and feature documentation

**Files:**
- Modify: `README.md`
- Modify: `docs/DESIGN.md`
- Modify: `docs/MILESTONE_6_PLAN.md`
- Modify: `.agents/skills/develop/references/gmail-receive-send-methods.md`
- Create: `.agents/skills/develop/references/oauth-provider-settings.md`

- [ ] **Step 1: Remove stale Google credential environment instructions**

Delete `MANIFOLD_GMAIL_CLIENT_ID` and `MANIFOLD_GMAIL_CLIENT_SECRET` from supported
environment lists and setup examples. State explicitly that legacy values are
ignored and are not imported.

Do not remove `MANIFOLD_CONNECTOR_ENCRYPTION_KEY`; document that it remains the
master key for provider secrets and user grants.

- [ ] **Step 2: Document the Settings workflow and provider extension contract**

README and design documentation must cover:

```text
Settings → OAuth → Gmail
/settings/oauth
/settings/oauth/gmail/help
```

Describe code-defined provider modules, generic encrypted rows, immediate runtime
resolution, secret non-rendering, reconnect effects, and the trusted-local Settings
boundary.

- [ ] **Step 3: Document non-rolling cutover**

Require operators to drain old Phoenix, connector, and Oban workers before
migration. State that Gmail is unavailable after deployment until credentials are
saved in Settings and existing Gmail accounts are reconnected.

- [ ] **Step 4: Add the repository feature reference**

Create `.agents/skills/develop/references/oauth-provider-settings.md` containing:

- module/table/migration ownership;
- catalog extension checklist;
- secret/AAD and browser-safety invariants;
- resolver consumers;
- setting UUID/version fence;
- save/rotate/remove lifecycle behavior;
- exact scoped test commands;
- migration up/down and staging checklist.

Update the Gmail reference to point to the new resolver and Settings/help routes.

- [ ] **Step 5: Run the stale-claim scan**

```sh
rg -n 'MANIFOLD_GMAIL_CLIENT_(ID|SECRET)|Gmail.*environment|provider.*restart' \
  README.md docs config apps .agents/skills/develop/references
```

Expected: legacy variable names remain only in tests proving they are ignored and
historical approved specs/plans where explicitly labeled as superseded; operator
instructions use Settings → OAuth.

- [ ] **Step 6: Commit**

```sh
git add README.md docs/DESIGN.md docs/MILESTONE_6_PLAN.md \
  .agents/skills/develop/references/gmail-receive-send-methods.md \
  .agents/skills/develop/references/oauth-provider-settings.md
git commit -m "docs: document OAuth provider settings"
```

---

### Task 9: Verify migrations, security invariants, and scoped regressions

**Files:**
- Modify only files already in scope when a failure is directly caused by this feature.
- Do not fix unrelated failures; report them and stop under the repository scope rule.

- [ ] **Step 1: Run formatting and strict compilation**

```sh
devenv shell -- mix format
devenv shell -- mix format --check-formatted
devenv shell -- mix compile --warnings-as-errors
```

Expected: all commands exit 0 without warnings.

- [ ] **Step 2: Run scoped application suites**

```sh
devenv shell -- mix test apps/manifold_data/test
devenv shell -- mix test apps/manifold_connectors/test
devenv shell -- mix test \
  apps/manifold_web/test/manifold_web/settings_live_test.exs \
  apps/manifold_web/test/manifold_web/oauth_settings_live_test.exs \
  apps/manifold_web/test/manifold_web/account_live_test.exs \
  apps/manifold_web/test/manifold_web/external_accounts_web_test.exs \
  apps/manifold_web/test/manifold_web/outbound_mail_live_test.exs
```

Expected: all in-scope tests pass.

- [ ] **Step 3: Run the fresh migration matrix**

On an isolated PostgreSQL database:

1. migrate the pre-feature schema;
2. seed a Gmail authorization/method, Microsoft method, and unconsumed OAuth state;
3. apply `20260818000100`;
4. verify no provider-setting row was imported from environment;
5. save Gmail settings and verify legacy Gmail rows become reconnect-required;
6. verify raw ciphertext does not contain the client secret;
7. rotate/remove/recreate and verify old OAuth states fail the generation fence;
8. remove settings/fenced transactions and verify down/up succeeds;
9. verify down refuses before DDL while a setting or fenced transaction exists.

- [ ] **Step 4: Verify browser secret safety**

Render and submit `/settings/oauth` with a unique sentinel secret. Search the
rendered HTML, LiveView test output, connector logs, telemetry captures, and
database plaintext fields. The sentinel may appear only after explicit decryption
inside the provider resolver test process.

- [ ] **Step 5: Verify live behavior without restart**

1. Open Add receive method and confirm Gmail is disabled.
2. Save Google credentials under Settings → OAuth.
3. Reopen Add receive/send method and confirm Gmail is enabled without restarting.
4. Remove configuration and confirm both pickers disable Gmail immediately.
5. Confirm existing Gmail rows display one reconnect action rather than becoming
   active silently.

Use fake provider endpoints unless real Google credentials are explicitly
available. Do not fabricate a live-provider pass.

- [ ] **Step 6: Inspect final scope**

```sh
git status --short
git diff main...HEAD --stat
git log --oneline main..HEAD
```

Expected: only approved OAuth settings source, tests, migration, docs, and feature
reference files changed. Preserve the unrelated untracked
`docs/superpowers/plans/2026-08-10-account-disable-async-delete.md`.

---

## Completion Criteria

- Gmail configuration is stored only in encrypted database settings.
- Old Google client ID/secret environment variables are ignored.
- Saving/removing settings changes Gmail availability immediately.
- Credential changes/removal require reconnection and cannot complete stale OAuth
  transactions.
- Secret plaintext never returns to the browser or observability surfaces.
- Gmail is rendered from a provider-neutral catalog and has a complete setup help
  page.
- Microsoft behavior is unchanged.
- Migrations, scoped tests, assets, formatting, and strict compilation pass.
