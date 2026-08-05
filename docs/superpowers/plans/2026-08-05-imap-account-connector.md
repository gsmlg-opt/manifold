# IMAP Account Connector Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let users add an IMAP account from the empty-state / Add account wizard, auto-create a local mailbox from the email address, and read-only sync INBOX into Manifold.

**Architecture:** Extend `manifold_connectors` with `provider = "imap"`, password credentials, IMAP settings, a minimal IMAP transport (real + fake), and Sync branching on `secret_kind`. Web wizard gains an IMAP path without mailbox selection; mail empty state CTA points at Add account.

**Tech Stack:** Elixir 1.18, Phoenix LiveView, Ecto, Oban, Erlang `:ssl`/`:gen_tcp` for IMAP, ExUnit.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-08-05-imap-account-connector-design.md`
- IMAP only; no POP3, no write-back, no multi-folder, no per-account SMTP send
- Import via `Ingest.import_external` with `source_kind = "provider_import"`
- Passwords encrypted with existing `Manifold.Connectors.Crypto` AES-GCM; never log plaintext
- TLS certificate verification on by default
- Domain/mailbox auto-created under the hood; UI never asks for domain
- Run tests via `devenv shell -- mix test …` unless already inside devenv
- Prefer TDD: failing test → implement → pass → commit per task

---

## File Map

- Create: `apps/manifold_data/priv/repo/migrations/20260805000100_add_imap_connector_support.exs`
- Modify: `apps/manifold_connectors/lib/manifold/connectors/schema/external_account.ex`
- Modify: `apps/manifold_connectors/lib/manifold/connectors/schema/credential.ex`
- Create: `apps/manifold_connectors/lib/manifold/connectors/schema/imap_settings.ex`
- Modify: `apps/manifold_accounts/lib/manifold/accounts.ex` — `ensure_mailbox_for_address/1`
- Modify: `apps/manifold_accounts/test/manifold/accounts_test.exs`
- Create: `apps/manifold_connectors/lib/manifold/connectors/imap/transport.ex` (behaviour)
- Create: `apps/manifold_connectors/lib/manifold/connectors/imap/client.ex` (minimal real client)
- Create: `apps/manifold_connectors/lib/manifold/connectors/imap/fake.ex` (test double)
- Create: `apps/manifold_connectors/lib/manifold/connectors/provider/imap.ex`
- Modify: `apps/manifold_connectors/lib/manifold/connectors/provider.ex` — optional OAuth callbacks
- Modify: `apps/manifold_connectors/lib/manifold/connectors.ex` — `test_imap_connection/1`, `create_imap_account/1`
- Modify: `apps/manifold_connectors/lib/manifold/connectors/sync.ex` — password auth + imap runtime
- Create/Modify tests under `apps/manifold_connectors/test/…`
- Modify: `apps/manifold_web/lib/manifold_web/live/external_account_live/new.ex`
- Modify: `apps/manifold_web/lib/manifold_web/live/mail_live/index.ex` — empty state CTA
- Modify: `apps/manifold_web/test/manifold_web/external_accounts_web_test.exs`
- Create or modify mail LiveView tests for empty-state CTA
- Modify: `apps/manifold_web/assets/css/app.css` only if IMAP form needs layout hooks already used by settings panels

---

### Task 1: Migration for IMAP settings and password credentials

**Files:**
- Create: `apps/manifold_data/priv/repo/migrations/20260805000100_add_imap_connector_support.exs`
- Test: run migration up/down in test env as smoke check

**Interfaces:**
- Produces: `connector_imap_settings` table; `connector_credentials.secret_kind` and `password_ciphertext`; nullable `refresh_token_ciphertext`

- [ ] **Step 1: Write the migration**

```elixir
defmodule Manifold.Repo.Migrations.AddImapConnectorSupport do
  use Ecto.Migration

  def up do
    alter table(:connector_credentials) do
      add(:secret_kind, :text, null: false, default: "oauth")
      add(:password_ciphertext, :binary)
      modify(:refresh_token_ciphertext, :binary, null: true, from: {:binary, null: false})
    end

    create(
      constraint(:connector_credentials, :connector_credentials_secret_kind_valid,
        check: "secret_kind IN ('oauth', 'password')"
      )
    )

    create(
      constraint(:connector_credentials, :connector_credentials_oauth_refresh_required,
        check: "secret_kind <> 'oauth' OR refresh_token_ciphertext IS NOT NULL"
      )
    )

    create(
      constraint(:connector_credentials, :connector_credentials_password_required,
        check: "secret_kind <> 'password' OR password_ciphertext IS NOT NULL"
      )
    )

    create table(:connector_imap_settings, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(
        :external_account_id,
        references(:connector_accounts, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:host, :text, null: false)
      add(:port, :integer, null: false)
      add(:tls_mode, :text, null: false)
      add(:username, :text, null: false)
      add(:mailbox_path, :text, null: false, default: "INBOX")

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:connector_imap_settings, [:external_account_id]))

    create(
      constraint(:connector_imap_settings, :connector_imap_settings_tls_mode_valid,
        check: "tls_mode IN ('ssl', 'starttls')"
      )
    )

    create(
      constraint(:connector_imap_settings, :connector_imap_settings_port_valid,
        check: "port > 0 AND port <= 65535"
      )
    )
  end

  def down do
    drop(table(:connector_imap_settings))

    drop(constraint(:connector_credentials, :connector_credentials_password_required))
    drop(constraint(:connector_credentials, :connector_credentials_oauth_refresh_required))
    drop(constraint(:connector_credentials, :connector_credentials_secret_kind_valid))

    alter table(:connector_credentials) do
      remove(:password_ciphertext)
      remove(:secret_kind)
      modify(:refresh_token_ciphertext, :binary, null: false, from: {:binary, null: true})
    end
  end
end
```

- [ ] **Step 2: Apply migration in test**

Run:

```bash
devenv shell -- mix ecto.migrate
```

Expected: migration applies with no errors.

- [ ] **Step 3: Commit**

```bash
git add apps/manifold_data/priv/repo/migrations/20260805000100_add_imap_connector_support.exs
git commit -m "feat(data): add IMAP connector settings and password credentials"
```

---

### Task 2: Schemas for IMAP settings, credentials, and provider allowlist

**Files:**
- Create: `apps/manifold_connectors/lib/manifold/connectors/schema/imap_settings.ex`
- Modify: `apps/manifold_connectors/lib/manifold/connectors/schema/credential.ex`
- Modify: `apps/manifold_connectors/lib/manifold/connectors/schema/external_account.ex`
- Create: `apps/manifold_connectors/test/manifold/connectors/schema/imap_support_test.exs`

**Interfaces:**
- Produces: `Manifold.Connectors.Schema.ImapSettings.changeset/2`
- Produces: `Credential.changeset/2` accepting `secret_kind` / `password_ciphertext`
- Produces: `ExternalAccount` allowing `provider: "imap"`

- [ ] **Step 1: Write failing schema tests**

```elixir
defmodule Manifold.Connectors.Schema.ImapSupportTest do
  use Manifold.DataCase, async: true

  alias Manifold.Connectors.Schema.{Credential, ExternalAccount, ImapSettings}

  test "external account accepts imap provider" do
    changeset =
      ExternalAccount.changeset(%ExternalAccount{}, %{
        mailbox_id: Ecto.UUID.generate(),
        provider: "imap",
        provider_account_id: "imap:user@example.com",
        email_address: "user@example.com",
        status: "connected",
        sync_enabled: true,
        granted_scopes: []
      })

    assert changeset.valid?
  end

  test "password credentials require password ciphertext and allow nil refresh" do
    changeset =
      Credential.changeset(%Credential{}, %{
        external_account_id: Ecto.UUID.generate(),
        key_version: 1,
        secret_kind: "password",
        password_ciphertext: <<1, 2, 3>>,
        refresh_token_ciphertext: nil
      })

    assert changeset.valid?
  end

  test "oauth credentials still require refresh token" do
    changeset =
      Credential.changeset(%Credential{}, %{
        external_account_id: Ecto.UUID.generate(),
        key_version: 1,
        secret_kind: "oauth",
        refresh_token_ciphertext: nil
      })

    refute changeset.valid?
    assert {"can't be blank", _} = changeset.errors[:refresh_token_ciphertext]
  end

  test "imap settings validate tls mode and port" do
    good =
      ImapSettings.changeset(%ImapSettings{}, %{
        external_account_id: Ecto.UUID.generate(),
        host: "imap.example.com",
        port: 993,
        tls_mode: "ssl",
        username: "user@example.com",
        mailbox_path: "INBOX"
      })

    assert good.valid?

    bad =
      ImapSettings.changeset(%ImapSettings{}, %{
        external_account_id: Ecto.UUID.generate(),
        host: "imap.example.com",
        port: 0,
        tls_mode: "plain",
        username: "user@example.com"
      })

    refute bad.valid?
  end
end
```

- [ ] **Step 2: Run tests — expect fail**

```bash
devenv shell -- mix test apps/manifold_connectors/test/manifold/connectors/schema/imap_support_test.exs
```

Expected: fail (module/fields missing).

- [ ] **Step 3: Implement schemas**

`imap_settings.ex`:

```elixir
defmodule Manifold.Connectors.Schema.ImapSettings do
  use Manifold.Connectors.Schema
  import Ecto.Changeset

  @tls_modes ~w(ssl starttls)

  schema "connector_imap_settings" do
    field(:external_account_id, :binary_id)
    field(:host, :string)
    field(:port, :integer)
    field(:tls_mode, :string)
    field(:username, :string)
    field(:mailbox_path, :string, default: "INBOX")

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(settings, attrs) do
    settings
    |> cast(attrs, [:external_account_id, :host, :port, :tls_mode, :username, :mailbox_path])
    |> validate_required([:external_account_id, :host, :port, :tls_mode, :username, :mailbox_path])
    |> validate_inclusion(:tls_mode, @tls_modes)
    |> validate_number(:port, greater_than: 0, less_than_or_equal_to: 65_535)
    |> validate_length(:host, min: 1, max: 253)
    |> validate_length(:username, min: 1, max: 320)
    |> validate_length(:mailbox_path, min: 1, max: 255)
    |> unique_constraint(:external_account_id)
  end
end
```

Update `Credential`:

- Add fields `secret_kind` (default `"oauth"`) and `password_ciphertext`
- Cast both
- `validate_required` base: `external_account_id`, `key_version`, `secret_kind`
- If `secret_kind == "oauth"`, require `refresh_token_ciphertext`
- If `secret_kind == "password"`, require `password_ciphertext`
- `validate_inclusion(:secret_kind, ~w(oauth password))`

Update `ExternalAccount` `validate_inclusion(:provider, ["gmail", "microsoft", "imap"])`.

- [ ] **Step 4: Run tests — expect pass**

```bash
devenv shell -- mix test apps/manifold_connectors/test/manifold/connectors/schema/imap_support_test.exs
```

- [ ] **Step 5: Commit**

```bash
git add apps/manifold_connectors/lib/manifold/connectors/schema/imap_settings.ex \
  apps/manifold_connectors/lib/manifold/connectors/schema/credential.ex \
  apps/manifold_connectors/lib/manifold/connectors/schema/external_account.ex \
  apps/manifold_connectors/test/manifold/connectors/schema/imap_support_test.exs
git commit -m "feat(connectors): schemas for IMAP settings and password secrets"
```

---

### Task 3: `Accounts.ensure_mailbox_for_address/1`

**Files:**
- Modify: `apps/manifold_accounts/lib/manifold/accounts.ex`
- Modify: `apps/manifold_accounts/test/manifold/accounts_test.exs`

**Interfaces:**
- Consumes: `Manifold.Core.Address.parse/1`, `create_domain/1`, `create_mailbox/2`
- Produces: `ensure_mailbox_for_address(String.t()) :: {:ok, Mailbox.t()} | {:error, Error.t() | Ecto.Changeset.t()}`
  - Returns mailbox preloaded with `:domain`
  - Creates domain + mailbox when missing; reuses when present and active

- [ ] **Step 1: Write failing tests**

```elixir
test "ensure_mailbox_for_address creates domain and mailbox" do
  assert {:ok, mailbox} = Accounts.ensure_mailbox_for_address("Person@Example.COM")
  assert mailbox.local_part == "Person"
  assert mailbox.domain.normalized_domain == "example.com"
  assert mailbox.active
end

test "ensure_mailbox_for_address reuses existing mailbox" do
  assert {:ok, first} = Accounts.ensure_mailbox_for_address("inbox@reuse.example")
  assert {:ok, second} = Accounts.ensure_mailbox_for_address("inbox@reuse.example")
  assert first.id == second.id
end

test "ensure_mailbox_for_address rejects invalid address" do
  assert {:error, %Manifold.Core.Error{}} = Accounts.ensure_mailbox_for_address("not-an-email")
end
```

- [ ] **Step 2: Run — expect fail**

```bash
devenv shell -- mix test apps/manifold_accounts/test/manifold/accounts_test.exs --only line:<new_test_line>
```

Or run the whole accounts test file and confirm the new tests fail.

- [ ] **Step 3: Implement**

```elixir
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
```

Note: `create_domain` / `create_mailbox` already call `insert_routing_resource/1`. If nesting transactions is unsafe in this codebase, implement ensure with a single Multi that inserts Domain/Mailbox directly via changesets + route revision bump matching `insert_routing_resource`. Prefer matching existing transaction style in `accounts.ex`.

- [ ] **Step 4: Run accounts tests — expect pass**

```bash
devenv shell -- mix test apps/manifold_accounts/test/manifold/accounts_test.exs
```

- [ ] **Step 5: Commit**

```bash
git add apps/manifold_accounts/lib/manifold/accounts.ex \
  apps/manifold_accounts/test/manifold/accounts_test.exs
git commit -m "feat(accounts): ensure mailbox from email address for IMAP setup"
```

---

### Task 4: IMAP transport behaviour, fake, and minimal client

**Files:**
- Create: `apps/manifold_connectors/lib/manifold/connectors/imap/transport.ex`
- Create: `apps/manifold_connectors/lib/manifold/connectors/imap/client.ex`
- Create: `apps/manifold_connectors/lib/manifold/connectors/imap/fake.ex`
- Create: `apps/manifold_connectors/test/manifold/connectors/imap/fake_test.exs`
- Create: `apps/manifold_connectors/test/manifold/connectors/imap/client_protocol_test.exs` (unit-test parser helpers without network)

**Interfaces:**
- Produces:

```elixir
defmodule Manifold.Connectors.IMAP.Transport do
  @type conn :: term()
  @type settings :: %{
          host: String.t(),
          port: pos_integer(),
          tls_mode: String.t(),
          username: String.t(),
          password: String.t(),
          mailbox_path: String.t()
        }

  @callback connect(settings()) :: {:ok, conn()} | {:error, Manifold.Connectors.Provider.Error.t()}
  @callback select(conn(), String.t()) ::
              {:ok, %{uidvalidity: pos_integer(), uidnext: pos_integer() | nil}}
              | {:error, Manifold.Connectors.Provider.Error.t()}
  @callback uid_search(conn(), String.t()) ::
              {:ok, [pos_integer()]} | {:error, Manifold.Connectors.Provider.Error.t()}
  @callback uid_fetch_rfc822(conn(), pos_integer()) ::
              {:ok, binary()} | {:error, Manifold.Connectors.Provider.Error.t()}
  @callback logout(conn()) :: :ok
end
```

- Fake stores messages in process/ETS keyed by test config; Client speaks tagged IMAP over SSL/STARTTLS for LOGIN, SELECT, UID SEARCH, UID FETCH RFC822, LOGOUT only.

- [ ] **Step 1: Write Fake tests**

```elixir
test "fake transport login select search fetch" do
  settings = %{
    host: "fake",
    port: 993,
    tls_mode: "ssl",
    username: "user@example.com",
    password: "secret",
    mailbox_path: "INBOX",
    messages: [{1, "Subject: one\r\n\r\nHi\r\n"}, {2, "Subject: two\r\n\r\nYo\r\n"}],
    uidvalidity: 9
  }

  assert {:ok, conn} = Fake.connect(settings)
  assert {:ok, %{uidvalidity: 9}} = Fake.select(conn, "INBOX")
  assert {:ok, [1, 2]} = Fake.uid_search(conn, "ALL")
  assert {:ok, "Subject: one" <> _} = Fake.uid_fetch_rfc822(conn, 1)
  assert :ok = Fake.logout(conn)
end

test "fake transport auth failure" do
  settings = %{
    host: "fake",
    port: 993,
    tls_mode: "ssl",
    username: "user@example.com",
    password: "wrong",
    mailbox_path: "INBOX",
    password_expected: "secret",
    messages: [],
    uidvalidity: 1
  }

  assert {:error, %Manifold.Connectors.Provider.Error{class: :reconnect}} = Fake.connect(settings)
end
```

- [ ] **Step 2: Implement Fake + Transport behaviour — tests pass**

- [ ] **Step 3: Implement Client with parse helpers**

Client requirements (YAGNI):

- `ssl` mode: `:ssl.connect(host, port, [verify: :verify_peer, cacerts: :public_key.cacerts_get(), …])`
- `ssl` mode: `:ssl.connect/3` with `verify: :verify_peer` and `cacerts: :public_key.cacerts_get()`
- `starttls` mode: `:gen_tcp.connect/3` → send `STARTTLS` → `:ssl.connect/2` upgrade with the same verify options
- Send tagged commands; read until tagged OK/NO/BAD
- SELECT parse `UIDVALIDITY`
- `UID SEARCH <set>` → list of integers
- `UID FETCH <uid> (RFC822)` → raw bytes
- Map NO login → `Error` class `:reconnect` code `:auth_failed`
- Map timeouts → `:temporary`

Prefer extracting pure parsers (`parse_search_response/1`, `parse_uidvalidity/1`, `extract_rfc822/1`) and unit-test those without sockets. Both `ssl` and `starttls` are required in this task.

- [ ] **Step 4: Commit**

```bash
git add apps/manifold_connectors/lib/manifold/connectors/imap \
  apps/manifold_connectors/test/manifold/connectors/imap
git commit -m "feat(connectors): IMAP transport behaviour with fake and client"
```

---

### Task 5: `Provider.IMAP` sync adapter

**Files:**
- Create: `apps/manifold_connectors/lib/manifold/connectors/provider/imap.ex`
- Modify: `apps/manifold_connectors/lib/manifold/connectors/provider.ex` (document optional OAuth callbacks; add `@optional_callbacks` for `exchange_code/5`, `refresh_token/3` if IMAP omits them)
- Create: `apps/manifold_connectors/test/manifold/connectors/provider/imap_test.exs`

**Interfaces:**
- Consumes: `Manifold.Connectors.IMAP.Transport` via `config[:transport]` (default `Client`)
- Produces module callbacks used by Sync:

```elixir
@spec initial_cursors(String.t(), keyword(), keyword()) ::
        {:ok, [Manifold.Connectors.Provider.SyncCursor.t()]} | {:error, Error.t()}
@spec sync_page(String.t(), SyncCursor.t(), keyword(), keyword()) ::
        {:ok, Page.t()} | {:error, Error.t()}
@spec fetch_raw(String.t(), String.t(), keyword(), keyword()) ::
        {:ok, RawMessage.t()} | {:error, Error.t()}
```

Auth material (`String.t()`) is the plaintext password for IMAP.

Config keyword keys: `:host`, `:port`, `:tls_mode`, `:username`, `:mailbox_path`, `:transport`, `:page_size` (default 50).

Cursor metadata:

```elixir
%{"uidvalidity" => integer(), "last_uid" => integer()}
```

Remote message id format: `"imap:<uidvalidity>:<uid>"`.

- [ ] **Step 1: Failing provider tests using Fake transport**

```elixir
test "bootstrap page returns messages and advances last_uid" do
  password = "secret"
  config = [
    host: "fake",
    port: 993,
    tls_mode: "ssl",
    username: "user@example.com",
    mailbox_path: "INBOX",
    transport: Fake,
    page_size: 1,
    fake: %{
      password_expected: password,
      uidvalidity: 3,
      messages: [{1, raw1}, {2, raw2}]
    }
  ]

  assert {:ok, [cursor]} = IMAP.initial_cursors(password, config, [])
  assert cursor.scope == "INBOX"
  assert cursor.phase == "bootstrap"

  assert {:ok, page} = IMAP.sync_page(password, cursor, config, [])
  assert length(page.messages) == 1
  assert hd(page.messages).id == "imap:3:1"
  assert page.cursor.metadata["last_uid"] == 1
end
```

Wire Fake so `connect` reads `config[:fake]` (or pass fake state in settings map built by Provider.IMAP).

- [ ] **Step 2: Implement Provider.IMAP**

Logic:

1. `initial_cursors` → one cursor `%{scope: mailbox_path, phase: "bootstrap", metadata: %{}}`
2. `sync_page`:
   - connect + select
   - if metadata uidvalidity missing: set from SELECT; search `1:*` or `ALL`
   - if uidvalidity changed vs metadata: reset `last_uid` to 0 and re-bootstrap
   - take next `page_size` UIDs where `uid > last_uid`
   - emit `RemoteMessage` structs with ids; do **not** fetch bodies here if existing Gmail pattern fetches in `fetch_raw` — match Sync’s existing `process_message` which calls `fetch_raw`
   - update cursor `last_uid` to last id in page; phase `"incremental"` when no more UIDs
3. `fetch_raw`: connect, select, `uid_fetch_rfc822`, return `%RawMessage{bytes: …, folder_kind: "inbox"}`

Always `logout` in an `after`/careful ensure.

- [ ] **Step 3: Tests pass + commit**

```bash
devenv shell -- mix test apps/manifold_connectors/test/manifold/connectors/provider/imap_test.exs
git add apps/manifold_connectors/lib/manifold/connectors/provider.ex \
  apps/manifold_connectors/lib/manifold/connectors/provider/imap.ex \
  apps/manifold_connectors/test/manifold/connectors/provider/imap_test.exs
git commit -m "feat(connectors): IMAP provider adapter for read-only INBOX sync"
```

---

### Task 6: `Connectors.test_imap_connection/1` and `create_imap_account/1`

**Files:**
- Modify: `apps/manifold_connectors/lib/manifold/connectors.ex`
- Modify: `apps/manifold_connectors/test/manifold/connectors_test.exs` (or new `imap_account_test.exs`)

**Interfaces:**
- Produces:

```elixir
@spec test_imap_connection(map()) :: :ok | {:error, Error.t() | ProviderError.t()}
# attrs: email_address, username, password, host, port, tls_mode, mailbox_path

@spec create_imap_account(map()) ::
        {:ok, ExternalAccount.t()} | {:error, Error.t() | Ecto.Changeset.t()}
# same attrs; on success persists account+settings+password credential+cursors+event+sync job
```

Rules:

- Normalize email via `Address.parse`
- `provider_account_id = "imap:" <> parsed.canonical`
- Reject if any non-disconnected `connector_accounts` row shares that email_address **or** that provider_account_id
- Call `Accounts.ensure_mailbox_for_address/1`
- Encrypt password with `Crypto.encrypt(password, "credential:#{account_id}:imap_password")` — define helper `credential_context(account_id, :imap_password)` next to existing `:access`/`:refresh`
- `granted_scopes: []`
- Load IMAP settings into adapter config at sync time (not only at create)
- `create_imap_account` must call `test_imap_connection` first (or accept `skip_test: true` only for internal tests that already mocked transport)

- [ ] **Step 1: Failing context tests with Fake transport configured via Application env**

```elixir
test "create_imap_account auto-creates mailbox and stores password credential" do
  Application.put_env(:manifold_connectors, :imap_transport, Manifold.Connectors.IMAP.Fake)
  # configure Fake expected password + empty inbox

  assert {:ok, account} =
           Connectors.create_imap_account(%{
             email_address: "reader@imap.example",
             username: "reader@imap.example",
             password: "secret",
             host: "imap.example",
             port: 993,
             tls_mode: "ssl"
           })

  assert account.provider == "imap"
  assert account.email_address == "reader@imap.example"
  mailbox = Accounts.get_mailbox!(account.mailbox_id)
  assert mailbox.domain.normalized_domain == "imap.example" or preload domain similarly

  credential = Repo.get_by!(Credential, external_account_id: account.id)
  assert credential.secret_kind == "password"
  assert is_binary(credential.password_ciphertext)
  assert is_nil(credential.refresh_token_ciphertext)

  assert Repo.get_by!(ImapSettings, external_account_id: account.id).host == "imap.example"
end

test "create_imap_account rejects auth failure without persisting" do
  # Fake password mismatch
  assert {:error, _} = Connectors.create_imap_account(%{... wrong password ...})
  assert Repo.aggregate(ExternalAccount, :count) == 0
end
```

- [ ] **Step 2: Implement API on `Manifold.Connectors`**

Also extend `runtime/1` consumers later in Task 7; here ensure settings persistence and job enqueue mirror `persist_authorization/7`.

Disconnect already deletes credentials; leave imap_settings rows (cascade on account delete only). No change required if settings FK cascades on account delete — disconnect does not delete the account row, so settings remain (fine for reconnect follow-up).

- [ ] **Step 3: Tests pass + commit**

```bash
devenv shell -- mix test apps/manifold_connectors/test/manifold/connectors/imap_account_test.exs
git add apps/manifold_connectors/lib/manifold/connectors.ex \
  apps/manifold_connectors/test/manifold/connectors/imap_account_test.exs
git commit -m "feat(connectors): create and test IMAP accounts"
```

---

### Task 7: Sync password branch and IMAP runtime

**Files:**
- Modify: `apps/manifold_connectors/lib/manifold/connectors/sync.ex`
- Modify: `apps/manifold_connectors/test/manifold/connectors/sync_test.exs` (add IMAP cases) or create `sync_imap_test.exs`

**Interfaces:**
- Consumes: `Credential.secret_kind`, `ImapSettings`, `Provider.IMAP`
- Changes: `access_token/5` → rename conceptually to auth material:

```elixir
defp auth_material(%ExternalAccount{provider: "imap"} = account, _adapter, _config, _now, _opts) do
  with %Credential{secret_kind: "password", password_ciphertext: cipher} <-
         Repo.get_by(Credential, external_account_id: account.id),
       {:ok, password} <- Crypto.decrypt(cipher, credential_context(account.id, :imap_password)) do
    {:ok, password}
  else
    nil -> {:error, Error.new(:permanent, :credential_missing, "…")}
    %Credential{} -> {:error, Error.new(:permanent, :credential_kind_mismatch, "…")}
    {:error, _} = error -> error
  end
end

defp auth_material(account, adapter, config, now, opts), do: access_token(account, adapter, config, now, opts)
```

- `runtime("imap")` builds config from `ImapSettings` + `:transport` from Application env (`:imap_transport`, default `Client`) + adapter `Provider.IMAP` (overridable via `:adapters` imap key like gmail)

- [ ] **Step 1: Failing sync test**

Seed IMAP account with Fake messages; run `Connectors.sync_account(account.id)`; assert `mailbox_entries` / inbound delivery exists for the mailbox (follow patterns in existing `sync_test.exs` for Gmail import).

- [ ] **Step 2: Implement runtime + auth_material branch; keep Gmail path unchanged**

- [ ] **Step 3: Run connector sync tests**

```bash
devenv shell -- mix test apps/manifold_connectors/test/manifold/connectors/sync_test.exs \
  apps/manifold_connectors/test/manifold/connectors/sync_imap_test.exs
```

Expected: all pass.

- [ ] **Step 4: Commit**

```bash
git add apps/manifold_connectors/lib/manifold/connectors/sync.ex \
  apps/manifold_connectors/test/manifold/connectors/sync_imap_test.exs
git commit -m "feat(connectors): sync IMAP accounts with password credentials"
```

---

### Task 8: Add account LiveView IMAP path

**Files:**
- Modify: `apps/manifold_web/lib/manifold_web/live/external_account_live/new.ex`
- Modify: `apps/manifold_web/test/manifold_web/external_accounts_web_test.exs`
- Modify: `apps/manifold_web/assets/css/app.css` only if new classes are required (reuse `.settings-*` / form patterns)

**Interfaces:**
- Consumes: `Connectors.create_imap_account/1`
- Wizard steps for IMAP: `:account_type` → `:imap_form` (no `:mailbox` step)
- Cloud path unchanged: `:account_type` → `:provider` → `:mailbox` → OAuth

- [ ] **Step 1: Failing LiveView tests**

```elixir
test "imap account type shows connection form without mailbox picker", %{conn: conn} do
  {:ok, view, _html} = live(conn, ~p"/settings/accounts/new")

  view
  |> element("button[phx-value-type='imap']", "IMAP account")
  |> render_click()

  html = render(view)
  assert html =~ "Host"
  refute html =~ "Choose a mailbox"
end

test "successful imap submit redirects to mailbox inbox", %{conn: conn} do
  # setup: Fake transport accepts password "secret"
  {:ok, view, _html} = live(conn, ~p"/settings/accounts/new")

  view |> element("button[phx-value-type='imap']", "IMAP account") |> render_click()

  view
  |> form("#imap-account-form", %{
    email_address: "reader@imap.example",
    username: "reader@imap.example",
    password: "secret",
    host: "imap.example",
    port: "993",
    tls_mode: "ssl"
  })
  |> render_submit()

  assert_redirect(view, ~r|/mail/.+/folders/.+|)
end

test "failed imap test connection does not create account", %{conn: conn} do
  # Fake expects a different password → form shows error; ExternalAccount count unchanged
end
```

Account type step changes:

- Keep event value `external` for the existing cloud path; label button **Cloud account**
- Add event value `imap`; label button **IMAP account**

Form fields: `email_address`, `username`, `password`, `host`, `port`, `tls_mode`. Default port `993`, tls `ssl`, username prefills from email via `phx-change`. Form id: `imap-account-form`.

- [ ] **Step 2: Implement LiveView events and template**

On save success:

```elixir
{:ok, folders} = Mail.list_folders(account.mailbox_id)
inbox = Enum.find(folders, &(&1.kind == "inbox"))
push_navigate(socket, to: ~p"/mail/#{account.mailbox_id}/folders/#{inbox.id}")
```

- [ ] **Step 3: Tests pass + commit**

```bash
devenv shell -- mix test apps/manifold_web/test/manifold_web/external_accounts_web_test.exs
git add apps/manifold_web/lib/manifold_web/live/external_account_live/new.ex \
  apps/manifold_web/test/manifold_web/external_accounts_web_test.exs \
  apps/manifold_web/assets/css/app.css
git commit -m "feat(web): add IMAP path to add-account wizard"
```

---

### Task 9: Empty-state CTA → Add account

**Files:**
- Modify: `apps/manifold_web/lib/manifold_web/live/mail_live/index.ex` (empty instance block ~635)
- Create: `apps/manifold_web/test/manifold_web/mail_live_test.exs`

**Interfaces:**
- Empty state primary link: `~p"/settings/accounts/new"` with visible text **Add account**
- Heading: `Connect an email account`
- Secondary link: `~p"/mailboxes"` with text **Manage local mailboxes**

- [ ] **Step 1: Failing test**

```elixir
test "empty state primary cta goes to add account", %{conn: conn} do
  {:ok, _view, html} = live(conn, ~p"/")
  assert html =~ ~p"/settings/accounts/new"
  assert html =~ "Add account"
  assert html =~ "Connect an email account"
  assert html =~ ~p"/mailboxes"
end
```

- [ ] **Step 2: Update HEEx empty state**

Replace:

```heex
<h1>Create a mailbox to begin</h1>
<.link navigate={~p"/mailboxes"} class="text-command">Open mailbox settings</.link>
```

With:

```heex
<h1>Connect an email account</h1>
<.link navigate={~p"/settings/accounts/new"} class="text-command">Add account</.link>
<.link navigate={~p"/mailboxes"}>Manage local mailboxes</.link>
```

- [ ] **Step 3: Tests pass + commit**

```bash
devenv shell -- mix test apps/manifold_web/test/manifold_web/mail_live_test.exs
git add apps/manifold_web/lib/manifold_web/live/mail_live/index.ex \
  apps/manifold_web/test/manifold_web/mail_live_test.exs
git commit -m "feat(web): point mail empty state at add-account flow"
```

---

### Task 10: Regression sweep + ADR note

**Files:**
- Create: `docs/adr/0008-imap-read-only-connector.md`
- Modify: `README.md` line that lists IMAP under permanent non-goals — keep POP3/JMAP out of scope; note read-only IMAP INBOX connector is supported

- [ ] **Step 1: Run focused + broader tests**

```bash
devenv shell -- mix test apps/manifold_connectors \
  apps/manifold_accounts/test/manifold/accounts_test.exs \
  apps/manifold_web/test/manifold_web/external_accounts_web_test.exs \
  apps/manifold_web/test/manifold_web/mail_live_test.exs
```

Expected: 0 failures.

- [ ] **Step 2: Write ADR 0008**

Include: context (ADR 0007 deferred IMAP), decision (password IMAP read-only INBOX via connectors), consequences (new settings/credentials, no write-back, POP3 still out).

- [ ] **Step 3: Update README non-goals** so IMAP is no longer listed as unimplemented forever; POP3/JMAP remain out of scope.

- [ ] **Step 4: Commit**

```bash
git add docs/adr/0008-imap-read-only-connector.md README.md
git commit -m "docs: accept read-only IMAP connector in ADR 0008"
```

---

## Spec coverage checklist

| Spec item | Task |
| --- | --- |
| Extend connectors with `provider=imap` | 2, 6, 7 |
| Auto domain/mailbox from email | 3, 6 |
| Hide domain in UI | 8, 9 |
| Password + TLS settings table | 1, 2, 6 |
| Test connection before save | 6, 8 |
| Read-only INBOX UID sync | 4, 5, 7 |
| `provider_import` ingest path | 7 |
| Empty-state Add account CTA | 9 |
| Accounts list Sync/Disconnect reuse | 6, 7 (no UI change beyond listing existing views) |
| No POP3 / write-back / SMTP send | Global constraints |
| Encrypted password, no plaintext logs | 6, 7 |
| LiveView + Fake adapter tests | 4–9 |

## Execution notes

- Prefer configuring `Application.put_env(:manifold_connectors, :imap_transport, Fake)` in tests; never hit public IMAP servers in CI.
- Keep Gmail/Microsoft `@behaviour` tests green when marking OAuth callbacks optional.
- If `create_domain` nested transactions conflict, implement ensure-mailbox with one Multi and shared route-revision bump — do not skip route revision.
