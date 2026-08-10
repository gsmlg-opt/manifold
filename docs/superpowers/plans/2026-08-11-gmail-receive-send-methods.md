# Gmail Receive and Send Methods Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Preserve real Gmail receive sync, add incrementally authorized Gmail API sending, make SMTP submission operational, and route each new outbound message through its account's enabled send method without implicit Resend fallback.

**Architecture:** `manifold_connectors` owns one encrypted Gmail authorization per Manifold account and exposes purpose-scoped OAuth plus a narrow send-method checkout API. `manifold_outbound` snapshots the enabled method at queue time, deterministically renders RFC messages, and dispatches through Gmail or SMTP adapters; legacy queued Resend submissions remain runnable. Ambiguous Gmail/SMTP acceptance transitions to `submission_uncertain` and is never retried automatically.

**Tech Stack:** Elixir 1.18, Phoenix LiveView, Ecto/PostgreSQL, Oban, Req, Erlang `:ssl`/`:gen_tcp`, ExUnit.

---

## Global constraints

- Approved spec: `docs/superpowers/specs/2026-08-11-gmail-receive-send-methods-design.md`
- Worktree: `.trees/gmail-receive-send-methods`, branch `codex/gmail-receive-send-methods`
- Use TDD in every behavioral task: failing focused test, minimal implementation, passing focused test, commit.
- One Gmail subject is permanently bound to one Manifold account; one account has at most one Gmail authorization.
- Gmail address equality uses the existing canonical address parser only; do not apply dot or plus normalization.
- Gmail receive continues to request `gmail.readonly`; Send incrementally adds `gmail.send`.
- Plain text only; no HTML, attachments, Gmail aliases, Graph send, push notifications, or remote mailbox mutation.
- Do not put tokens, passwords, authorization codes, raw messages, or message bodies in logs, telemetry metadata, Oban args, or error details.
- Newly queued mail requires an enabled Gmail or SMTP method. Do not silently route it through Resend.
- Existing queued `provider = "resend"` rows must remain dispatchable after deployment.
- Run commands through `devenv shell --` unless the shell is already inside devenv.

## File map

### Data and connector authorization

- Create: `apps/manifold_data/priv/repo/migrations/20260811000100_add_shared_gmail_authorizations.exs`
- Create: `apps/manifold_connectors/lib/manifold/connectors/schema/oauth_authorization.ex`
- Create: `apps/manifold_connectors/lib/manifold/connectors/gmail_scopes.ex`
- Modify: `apps/manifold_connectors/lib/manifold/connectors/schema/oauth_transaction.ex`
- Modify: `apps/manifold_connectors/lib/manifold/connectors/schema/receive_method.ex`
- Modify: `apps/manifold_connectors/lib/manifold/connectors/schema/send_method.ex`
- Create: `apps/manifold_connectors/lib/manifold/connectors/gmail_authorizations.ex`
- Create: `apps/manifold_connectors/lib/manifold/connectors/submission_method.ex`
- Modify: `apps/manifold_connectors/lib/manifold/connectors/oauth.ex`
- Modify: `apps/manifold_connectors/lib/manifold/connectors.ex`
- Modify: `apps/manifold_connectors/lib/manifold/connectors/sync.ex`
- Modify: connector OAuth, context, sync, schema, and SMTP tests under `apps/manifold_connectors/test/manifold/connectors/`

### Outbound routing and providers

- Modify: `apps/manifold_outbound/mix.exs`
- Modify: `apps/manifold_outbound/lib/manifold/outbound/provider.ex`
- Modify: `apps/manifold_outbound/lib/manifold/outbound/schema/provider_submission.ex`
- Create: `apps/manifold_outbound/lib/manifold/outbound/rfc_message.ex`
- Create: `apps/manifold_outbound/lib/manifold/outbound/provider/gmail.ex`
- Create: `apps/manifold_outbound/lib/manifold/outbound/provider/smtp.ex`
- Modify: `apps/manifold_outbound/lib/manifold/outbound/provider/resend.ex`
- Modify: `apps/manifold_outbound/lib/manifold/outbound.ex`
- Modify: `apps/manifold_outbound/lib/manifold/outbound/submission.ex`
- Modify: `apps/manifold_outbound/lib/manifold/outbound/jobs/submit_outbound.ex`
- Create/modify focused tests under `apps/manifold_outbound/test/manifold/outbound/`

### SMTP transport, web, and documentation

- Modify: `apps/manifold_connectors/lib/manifold/connectors/smtp/transport.ex`
- Modify: `apps/manifold_connectors/lib/manifold/connectors/smtp/client.ex`
- Modify: `apps/manifold_connectors/lib/manifold/connectors/smtp/fake.ex`
- Modify: `apps/manifold_web/lib/manifold_web/controllers/connector_oauth_controller.ex`
- Modify: `apps/manifold_web/lib/manifold_web/live/account_live/receive_method_new.ex`
- Modify: `apps/manifold_web/lib/manifold_web/live/account_live/send_method_new.ex`
- Modify: `apps/manifold_web/lib/manifold_web/live/account_live/show.ex`
- Modify: `apps/manifold_web/lib/manifold_web/live/mail_live/index.ex`
- Modify: `apps/manifold_web/test/manifold_web/account_live_test.exs`
- Modify: `apps/manifold_web/test/manifold_web/external_accounts_web_test.exs`
- Modify: `apps/manifold_web/test/manifold_web/outbound_mail_live_test.exs`
- Create: `docs/adr/0010-account-selected-outbound-methods.md`
- Modify: `docs/adr/0007-read-only-provider-connectors.md`
- Modify: `docs/DESIGN.md`
- Modify: `README.md`
- Create: `.agents/skills/develop/references/gmail-receive-send-methods.md`

---

### Task 1: Add shared Gmail authorization and outbound snapshot storage

**Files:**
- Create: `apps/manifold_data/priv/repo/migrations/20260811000100_add_shared_gmail_authorizations.exs`
- Create: `apps/manifold_connectors/lib/manifold/connectors/schema/oauth_authorization.ex`
- Create: `apps/manifold_connectors/lib/manifold/connectors/gmail_scopes.ex`
- Modify: `apps/manifold_connectors/lib/manifold/connectors/schema/oauth_transaction.ex:7-40`
- Modify: `apps/manifold_connectors/lib/manifold/connectors/schema/receive_method.ex:10-76`
- Modify: `apps/manifold_connectors/lib/manifold/connectors/schema/send_method.ex:7-49`
- Modify: `apps/manifold_outbound/lib/manifold/outbound/schema/provider_submission.ex:7-66`
- Create: `apps/manifold_connectors/test/manifold/connectors/schema/gmail_authorization_test.exs`

**Interfaces:**

```elixir
%Manifold.Connectors.Schema.OAuthAuthorization{
  account_id: account_id,
  provider: "gmail",
  provider_subject_id: google_sub,
  email_address: canonical_email,
  granted_scopes: scopes,
  status: "connected"
}

%ProviderSubmission{
  send_method_id: method_id,
  provider: "gmail",
  provider_rfc_message_id: message_id,
  request_sha256: lowercase_sha256
}
```

- [ ] **Step 1: Write failing schema tests**

Create tests that assert:

```elixir
test "Gmail authorization requires identity, scopes, and connected status" do
  changeset =
    OAuthAuthorization.changeset(%OAuthAuthorization{}, %{
      account_id: Ecto.UUID.generate(),
      provider: "gmail",
      provider_subject_id: "google-sub-1",
      email_address: "person@gmail.com",
      granted_scopes: ["openid", "email", GmailScopes.read()],
      status: "connected",
      refresh_token_ciphertext: <<1, 2, 3>>
    })

  assert changeset.valid?
end

test "send methods accept Gmail and retain SMTP" do
  for kind <- ~w(gmail smtp) do
    assert SendMethod.changeset(%SendMethod{}, %{
             account_id: Ecto.UUID.generate(),
             kind: kind,
             email_address: "person@gmail.com",
             status: "connected",
             enabled: true
           }).valid?
  end
end

test "OAuth transactions require a purpose and required scopes" do
  changeset =
    OAuthTransaction.changeset(%OAuthTransaction{}, %{
      state_digest: :crypto.strong_rand_bytes(32),
      provider: "gmail",
      mailbox_id: Ecto.UUID.generate(),
      purpose: "send",
      required_scopes: [GmailScopes.send()],
      pkce_verifier_ciphertext: <<1, 2, 3>>,
      redirect_uri: "https://mail.example.test/connectors/gmail/callback",
      expires_at: DateTime.add(DateTime.utc_now(), 600)
    })

  assert changeset.valid?
  assert Ecto.Changeset.get_field(changeset, :purpose) == "send"
end

test "Gmail provider submissions do not require a Resend idempotency expiry" do
  changeset = ProviderSubmission.changeset(%ProviderSubmission{}, %{
    outbound_message_id: Ecto.UUID.generate(),
    send_method_id: Ecto.UUID.generate(),
    provider: "gmail",
    idempotency_key: Ecto.UUID.generate(),
    request_sha256: String.duplicate("a", 64),
    state: "pending",
    attempt_count: 0,
    idempotency_expires_at: nil
  })

  assert changeset.valid?
end
```

- [ ] **Step 2: Run the tests and verify they fail**

```sh
devenv shell -- mix test apps/manifold_connectors/test/manifold/connectors/schema/gmail_authorization_test.exs
```

Expected: compile failure because `OAuthAuthorization`, the new fields, and Gmail send kind do not exist.

- [ ] **Step 3: Write the migration**

Implement `up/0` with these exact operations:

```elixir
create table(:connector_oauth_authorizations, primary_key: false) do
  add(:id, :binary_id, primary_key: true)
  add(:mailbox_id, references(:mailboxes, type: :binary_id, on_delete: :delete_all), null: false)
  add(:provider, :text, null: false)
  add(:provider_subject_id, :text, null: false)
  add(:email_address, :text, null: false)
  add(:granted_scopes, {:array, :text}, null: false, default: [])
  add(:status, :text, null: false, default: "connected")
  add(:key_version, :integer, null: false, default: 1)
  add(:access_token_ciphertext, :binary)
  add(:refresh_token_ciphertext, :binary)
  add(:token_expires_at, :utc_datetime_usec)
  add(:last_error_class, :text)
  add(:last_error_code, :text)
  add(:last_error_message, :text)
  add(:disconnected_at, :utc_datetime_usec)
  add(:lock_version, :integer, null: false, default: 1)
  timestamps(type: :utc_datetime_usec)
end

create(unique_index(:connector_oauth_authorizations, [:mailbox_id, :provider]))
create(unique_index(:connector_oauth_authorizations, [:provider, :provider_subject_id]))
create(constraint(:connector_oauth_authorizations, :oauth_authorizations_connected_refresh_required,
  check: "status <> 'connected' OR refresh_token_ciphertext IS NOT NULL"))

alter table(:connector_accounts) do
  add(:oauth_authorization_id, references(:connector_oauth_authorizations, type: :binary_id, on_delete: :restrict))
end

alter table(:connector_send_methods) do
  add(:oauth_authorization_id, references(:connector_oauth_authorizations, type: :binary_id, on_delete: :restrict))
end

alter table(:connector_oauth_transactions) do
  add(:purpose, :text, null: false, default: "receive")
  add(:required_scopes, {:array, :text}, null: false, default: [])
end

alter table(:provider_submissions) do
  add(:send_method_id, references(:connector_send_methods, type: :binary_id, on_delete: :restrict))
  modify(:idempotency_expires_at, :utc_datetime_usec, null: true,
    from: {:utc_datetime_usec, null: false})
end
```

Backfill Gmail rows with authorization `id = connector_accounts.id`; copy token columns from `connector_credentials`, set `connector_accounts.oauth_authorization_id`, then delete only the migrated Gmail OAuth credential rows. Reusing the receive-method UUID preserves the existing AES-GCM context `credential:<id>:access|refresh`. Leave Microsoft and password credentials untouched.

Drop and recreate `connector_send_methods_kind_valid` as `kind IN ('smtp', 'gmail')`. Add purpose/status/provider/FK constraints. `down/0` must refuse lossy rollback when Gmail send methods exist, restore migrated Gmail credential rows with the same IDs/context, remove snapshot/auth columns, and drop the authorization table.

- [ ] **Step 4: Add schemas and field casts**

Implement `OAuthAuthorization.changeset/2` with provider `gmail`, statuses `connected|reconnect_required|disconnected`, sorted unique scopes, address/error length validation, optimistic locking, the two named unique constraints, and refresh-token validation only while status is `connected`. Add `oauth_authorization_id` to ReceiveMethod and SendMethod; add `purpose`/`required_scopes` to OAuthTransaction; add `send_method_id` to ProviderSubmission; permit `gmail` in SendMethod. Make ProviderSubmission require `idempotency_expires_at` only for legacy `provider == "resend"` rows so Gmail/SMTP can store nil.

Create the only canonical Gmail scope constants now so later tasks share names:

```elixir
defmodule Manifold.Connectors.GmailScopes do
  @read "https://www.googleapis.com/auth/gmail.readonly"
  @send "https://www.googleapis.com/auth/gmail.send"
  def read, do: @read
  def send, do: @send
end
```

- [ ] **Step 5: Run migration and schema tests**

```sh
devenv shell -- mix ecto.migrate
devenv shell -- mix test apps/manifold_connectors/test/manifold/connectors/schema/gmail_authorization_test.exs
```

Expected: migration succeeds; schema tests pass.

- [ ] **Step 6: Commit**

```sh
git add apps/manifold_data/priv/repo/migrations/20260811000100_add_shared_gmail_authorizations.exs \
  apps/manifold_connectors/lib/manifold/connectors/schema/oauth_authorization.ex \
  apps/manifold_connectors/lib/manifold/connectors/gmail_scopes.ex \
  apps/manifold_connectors/lib/manifold/connectors/schema/oauth_transaction.ex \
  apps/manifold_connectors/lib/manifold/connectors/schema/receive_method.ex \
  apps/manifold_connectors/lib/manifold/connectors/schema/send_method.ex \
  apps/manifold_outbound/lib/manifold/outbound/schema/provider_submission.ex \
  apps/manifold_connectors/test/manifold/connectors/schema/gmail_authorization_test.exs
git commit -m "feat(data): add shared Gmail authorizations"
```

---

### Task 2: Make OAuth purpose-scoped and incremental

**Files:**
- Modify: `apps/manifold_connectors/lib/manifold/connectors/oauth.ex:16-187`
- Modify: `apps/manifold_connectors/test/manifold/connectors/oauth_test.exs`

**Interfaces:**

```elixir
OAuth.start("gmail", account_id, redirect_uri, purpose: :send)
# => initial URL scopes: openid email gmail.send; stored purpose: "send"
# => existing receive grant URL scopes: openid email gmail.readonly gmail.send

%OAuth.Consumed{
  provider: "gmail",
  account_id: account_id,
  purpose: :send,
  required_scopes: [GmailScopes.send()],
  redirect_uri: redirect_uri,
  pkce_verifier: verifier
}
```

- [ ] **Step 1: Add failing purpose/scope tests**

```elixir
test "send purpose requests gmail.send and survives consume", %{mailbox: mailbox} do
  assert {:ok, authorization} =
           OAuth.start("gmail", mailbox.id, @redirect_uri, purpose: :send, now: @now)

  query = authorization.url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
  assert query["scope"] =~ GmailScopes.send()
  refute query["scope"] =~ GmailScopes.read()

  assert {:ok, consumed} =
           OAuth.consume("gmail", authorization.state, @redirect_uri, now: @now)

  assert consumed.purpose == :send
  assert consumed.required_scopes == [GmailScopes.send()]
end
```

Also prove `purpose: :receive` requests read scope, an existing receive authorization causes Send to request the union of read plus send, Microsoft rejects send purpose, and invalid purpose creates no transaction.

- [ ] **Step 2: Run and verify failure**

```sh
devenv shell -- mix test apps/manifold_connectors/test/manifold/connectors/oauth_test.exs
```

Expected: assertions fail because OAuth always requests Gmail readonly and Consumed lacks purpose/scopes.

- [ ] **Step 3: Implement purpose mapping**

Add:

```elixir
def required_scopes("gmail", :receive), do: [GmailScopes.read()]
def required_scopes("gmail", :send), do: [GmailScopes.send()]
def required_scopes("microsoft", :receive), do: ["Mail.Read", "offline_access"]

defp identity_scopes("gmail"), do: ["openid", "email"]
defp identity_scopes("microsoft"), do: ["openid", "profile", "User.Read"]
```

Normalize `:receive|:send` before persistence. Load any existing Gmail authorization by account, union its granted scopes with the new purpose scope, store that full required set, add it to `Consumed`, and build the URL from identity plus the union. Never accept scope strings from request parameters. Keep Gmail `include_granted_scopes=true`, offline access, consent prompt, PKCE, one-time state, and redirect equality unchanged.

- [ ] **Step 4: Run OAuth tests**

```sh
devenv shell -- mix test apps/manifold_connectors/test/manifold/connectors/oauth_test.exs
```

Expected: all OAuth tests pass.

- [ ] **Step 5: Commit**

```sh
git add apps/manifold_connectors/lib/manifold/connectors/oauth.ex \
  apps/manifold_connectors/test/manifold/connectors/oauth_test.exs
git commit -m "feat(connectors): add purpose-scoped Gmail OAuth"
```

---

### Task 3: Persist and incrementally upgrade shared Gmail authorization

**Files:**
- Create: `apps/manifold_connectors/lib/manifold/connectors/gmail_authorizations.ex`
- Modify: `apps/manifold_connectors/lib/manifold/connectors.ex:41-75,753-950`
- Modify: `apps/manifold_connectors/test/manifold/connectors_test.exs`
- Create: `apps/manifold_connectors/test/manifold/connectors/gmail_authorizations_test.exs`

**Interfaces:**

```elixir
Connectors.complete_authorization("gmail", code, consumed)
# receive => {:ok, %ReceiveMethod{}}
# send    => {:ok, %SendMethod{kind: "gmail"}}

GmailAuthorizations.complete(code, consumed, adapter, config, opts)
GmailAuthorizations.disconnect_method(:receive | :send, method_id)
GmailAuthorizations.mark_reconnect_required(authorization_id, provider_error)
```

- [ ] **Step 1: Write failing completion and binding tests**

Cover these concrete cases:

```elixir
test "receive grant creates shared authorization and receive method" do
  assert {:ok, receive} = complete(:receive, account, read_token(), identity("one@gmail.com"))
  authorization = Repo.get!(OAuthAuthorization, receive.oauth_authorization_id)
  assert authorization.account_id == account.id
  assert authorization.provider_subject_id == "google-sub-1"
  assert GmailScopes.read() in authorization.granted_scopes
end

test "send upgrade preserves read scope and refresh token" do
  receive = connect_receive(account)
  before = Repo.get!(OAuthAuthorization, receive.oauth_authorization_id)
  assert {:ok, send_method} = complete(:send, account, send_token(refresh_token: nil), same_identity())
  after_auth = Repo.get!(OAuthAuthorization, send_method.oauth_authorization_id)
  assert MapSet.new(after_auth.granted_scopes) ==
           MapSet.new([GmailScopes.read(), GmailScopes.send()])
  assert after_auth.refresh_token_ciphertext == before.refresh_token_ciphertext
end
```

Also test send-first/read-upgrade, missing union scope, canonical address mismatch, subject mismatch, subject already bound to another account, distinct subjects on distinct accounts, final-disconnect token erasure with retained subject binding, and account deletion cascading through both Gmail methods and the authorization.

- [ ] **Step 2: Run and verify failure**

```sh
devenv shell -- mix test apps/manifold_connectors/test/manifold/connectors/gmail_authorizations_test.exs \
  apps/manifold_connectors/test/manifold/connectors_test.exs
```

Expected: failures because completion still owns tokens on ReceiveMethod credentials and always creates receive cursors/jobs.

- [ ] **Step 3: Implement focused Gmail authorization context**

`GmailAuthorizations.complete/5` must:

1. Exchange the code and load Google identity.
2. Canonicalize provider and account addresses through `Manifold.Core.Address.parse/1` and require equality.
3. Lock authorization by account and by provider subject.
4. Require the union of stored scopes plus `consumed.required_scopes` in the returned token scopes.
5. Encrypt access/refresh tokens with `credential:<authorization.id>:access|refresh`.
6. Preserve existing refresh ciphertext when the token omits refresh.
7. Upsert only the requested method, disabling other methods in that direction.
8. For Receive only, initialize cursors and enqueue Sync transactionally.
9. Record `connected` or `scope_upgraded` connector activity.

Keep Microsoft on the existing completion path. Make `Connectors.complete_authorization/4` dispatch Gmail to the new module and Microsoft to the old receive-only path.

- [ ] **Step 4: Implement lifecycle operations**

When a Gmail method disconnects, delete/disable that method's dependent settings only. Count remaining ReceiveMethod and SendMethod references inside the same transaction; if zero, set authorization `disconnected`, clear both ciphertext fields and expiry, but retain account, subject, and address. A reconnect must match that retained subject.

- [ ] **Step 5: Run focused tests**

```sh
devenv shell -- mix test apps/manifold_connectors/test/manifold/connectors/gmail_authorizations_test.exs \
  apps/manifold_connectors/test/manifold/connectors_test.exs
```

Expected: all pass, including existing Microsoft completion cases.

- [ ] **Step 6: Commit**

```sh
git add apps/manifold_connectors/lib/manifold/connectors/gmail_authorizations.ex \
  apps/manifold_connectors/lib/manifold/connectors.ex \
  apps/manifold_connectors/test/manifold/connectors/gmail_authorizations_test.exs \
  apps/manifold_connectors/test/manifold/connectors_test.exs
git commit -m "feat(connectors): share incremental Gmail authorization"
```

---

### Task 4: Share serialized Gmail token refresh with receive sync and send checkout

**Files:**
- Modify: `apps/manifold_connectors/lib/manifold/connectors/gmail_authorizations.ex`
- Modify: `apps/manifold_connectors/lib/manifold/connectors/sync.ex:377-453`
- Modify: `apps/manifold_connectors/test/manifold/connectors/sync_test.exs`
- Modify: `apps/manifold_connectors/test/manifold/connectors/gmail_authorizations_test.exs`

**Interfaces:**

```elixir
Connectors.checkout_oauth_access_token(authorization_id,
  required_scope: GmailScopes.send(),
  now: now,
  provider_opts: opts
)
# => {:ok, access_token} | {:error, Core.Error.t() | Provider.Error.t()}
```

- [ ] **Step 1: Write failing refresh tests**

Test a current token avoids refresh, expired token refreshes once under `FOR UPDATE`, two concurrent callers both receive the refreshed token but invoke the adapter once, refresh-token rotation persists, missing required scope fails before provider I/O, and `invalid_grant` marks the authorization plus both methods `reconnect_required`.

Use an Agent counter/barrier in the fake Gmail adapter so the concurrency assertion is deterministic:

```elixir
assert [ok: "new-access", ok: "new-access"] =
         1..2
         |> Task.async_stream(fn _ -> Connectors.checkout_oauth_access_token(auth.id, opts) end,
           ordered: true,
           max_concurrency: 2
         )
         |> Enum.map(fn {:ok, {:ok, token}} -> {:ok, token} end)

assert Agent.get(refresh_count, & &1) == 1
```

- [ ] **Step 2: Run and verify failure**

```sh
devenv shell -- mix test apps/manifold_connectors/test/manifold/connectors/gmail_authorizations_test.exs
```

- [ ] **Step 3: Implement refresh-under-lock**

Expose `Connectors.checkout_oauth_access_token/2` as the public delegate to the focused authorization module. Inside one transaction, lock the authorization, re-check expiry after the lock, validate the required scope, decrypt refresh token, call the configured Gmail adapter, encrypt returned tokens, merge/validate scopes, and update status/errors. Convert provider reconnect errors through one function that updates the authorization and all referenced Gmail methods before returning.

- [ ] **Step 4: Switch Gmail Sync to the shared token path**

In `Sync.auth_material/5`, use `account.oauth_authorization_id` for Gmail and retain the existing Credential path for Microsoft, IMAP, and EAS. Do not change cursor processing or ingest behavior.

- [ ] **Step 5: Run sync and authorization tests**

```sh
devenv shell -- mix test apps/manifold_connectors/test/manifold/connectors/gmail_authorizations_test.exs \
  apps/manifold_connectors/test/manifold/connectors/sync_test.exs \
  apps/manifold_connectors/test/manifold/connectors/provider/gmail_test.exs
```

- [ ] **Step 6: Commit**

```sh
git add apps/manifold_connectors/lib/manifold/connectors/gmail_authorizations.ex \
  apps/manifold_connectors/lib/manifold/connectors/sync.ex \
  apps/manifold_connectors/test/manifold/connectors/gmail_authorizations_test.exs \
  apps/manifold_connectors/test/manifold/connectors/sync_test.exs
git commit -m "refactor(connectors): share Gmail token refresh"
```

---

### Task 5: Expose safe account send-method selection and checkout

**Files:**
- Create: `apps/manifold_connectors/lib/manifold/connectors/submission_method.ex`
- Modify: `apps/manifold_connectors/lib/manifold/connectors.ex:306-449,1607-1742`
- Modify: `apps/manifold_connectors/test/manifold/connectors/smtp_send_method_test.exs`
- Create: `apps/manifold_connectors/test/manifold/connectors/submission_method_test.exs`

**Interfaces:**

```elixir
Connectors.enabled_send_method(account_id)
# => {:ok, %SubmissionMethod{id: id, kind: "gmail" | "smtp", email_address: address}}
#  | {:error, %Core.Error{reason: :send_method_required}}

Connectors.checkout_send_method(method_id, required_sender, opts)
# gmail => {:ok, %SubmissionMethod{credential: {:oauth, token}, config: gmail_config}}
# smtp  => {:ok, %SubmissionMethod{credential: {:password, password}, config: smtp_settings}}
```

- [ ] **Step 1: Write failing resolver tests**

Prove no enabled method returns `:send_method_required`, SMTP/Gmail selection is account-scoped, sender mismatch is permanent, disconnected or later-disabled method cannot check out, Gmail checkout requires `gmail.send`, and SMTP checkout decrypts the purpose-bound password without exposing it in `inspect/1`.

```elixir
assert {:error, %Error{reason: :send_method_required}} =
         Connectors.enabled_send_method(account.id)

assert {:ok, %SubmissionMethod{kind: "gmail", id: ^gmail.id}} =
         Connectors.enabled_send_method(account.id)
```

- [ ] **Step 2: Run and verify failure**

```sh
devenv shell -- mix test apps/manifold_connectors/test/manifold/connectors/submission_method_test.exs
```

- [ ] **Step 3: Implement the DTO and APIs**

Keep `SubmissionMethod` free of Ecto schemas. Redact `credential` in `Inspect`; return identity/config only at checkout. Lock the method row during checkout, require `enabled`, `connected`, matching account sender, and obtain Gmail token through Task 4 or SMTP settings/password through the existing encrypted records.

Update SMTP creation so `parsed.canonical == Accounts.account_address(mailbox)`; return `:sender_address_mismatch` before connection testing/persistence otherwise.

- [ ] **Step 4: Run connector send-method tests**

```sh
devenv shell -- mix test apps/manifold_connectors/test/manifold/connectors/submission_method_test.exs \
  apps/manifold_connectors/test/manifold/connectors/smtp_send_method_test.exs
```

- [ ] **Step 5: Commit**

```sh
git add apps/manifold_connectors/lib/manifold/connectors/submission_method.ex \
  apps/manifold_connectors/lib/manifold/connectors.ex \
  apps/manifold_connectors/test/manifold/connectors/submission_method_test.exs \
  apps/manifold_connectors/test/manifold/connectors/smtp_send_method_test.exs
git commit -m "feat(connectors): resolve account send methods"
```

---

### Task 6: Render deterministic provider-specific RFC messages

**Files:**
- Create: `apps/manifold_outbound/lib/manifold/outbound/rfc_message.ex`
- Modify: `apps/manifold_outbound/lib/manifold/outbound/provider.ex:40-68`
- Modify: `apps/manifold_outbound/lib/manifold/outbound/provider/resend.ex:23-67`
- Create: `apps/manifold_outbound/test/manifold/outbound/rfc_message_test.exs`

**Interfaces:**

```elixir
RfcMessage.render(envelope,
  provider: :gmail | :smtp,
  message_id: "<3f40abf2-5ae5-4f4a-91ee-981686f7949b@manifold.local>",
  date: queued_at
)
# => {:ok, binary()} | {:error, Core.Error.t()}
```

- [ ] **Step 1: Write RFC fixture assertions**

Assert CRLF line endings, stable Date and Message-ID, encoded UTF-8 subject/body, `In-Reply-To`, folded References, header-injection rejection, dot-leading body preservation before SMTP framing, and these Bcc differences:

```elixir
assert gmail_raw =~ "Bcc: hidden@example.net\r\n"
refute smtp_raw =~ "Bcc:"
assert gmail_raw == RfcMessage.render!(envelope, gmail_opts)
assert smtp_raw == RfcMessage.render!(envelope, smtp_opts)
```

- [ ] **Step 2: Run and verify failure**

```sh
devenv shell -- mix test apps/manifold_outbound/test/manifold/outbound/rfc_message_test.exs
```

- [ ] **Step 3: Implement the renderer**

Create focused helpers for address headers, unstructured header encoding, references folding, body transfer encoding, and CRLF normalization. Use only queued timestamp and stable IDs; never call the current clock or random functions from `render/2`.

Extend `Provider.Envelope` with `message_id` and `queued_at`, define `Provider.Request`, and change the behavior callback to accept Request:

```elixir
defmodule Manifold.Outbound.Provider.Request do
  @enforce_keys [:provider, :send_method_id, :envelope, :raw_message, :request_sha256]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          provider: String.t(),
          send_method_id: Ecto.UUID.t(),
          envelope: Manifold.Outbound.Provider.Envelope.t(),
          raw_message: binary(),
          request_sha256: String.t()
        }
end

@callback submit(keyword(), Request.t()) ::
            {:ok, Submission.t()} | {:error, Error.t()}
```

Adapt Resend now with `submit(config, %Request{envelope: envelope})`, delegating to its existing payload logic. Retain a temporary `%Envelope{}` compatibility clause so the unchanged Submission module and existing Resend tests continue to pass until Task 10 switches all dispatch to Request.

- [ ] **Step 4: Run renderer tests**

```sh
devenv shell -- mix test apps/manifold_outbound/test/manifold/outbound/rfc_message_test.exs
```

- [ ] **Step 5: Commit**

```sh
git add apps/manifold_outbound/lib/manifold/outbound/rfc_message.ex \
  apps/manifold_outbound/lib/manifold/outbound/provider.ex \
  apps/manifold_outbound/lib/manifold/outbound/provider/resend.ex \
  apps/manifold_outbound/test/manifold/outbound/rfc_message_test.exs
git commit -m "feat(outbound): render deterministic RFC messages"
```

---

### Task 7: Snapshot the enabled send method while queueing

**Files:**
- Modify: `apps/manifold_outbound/mix.exs:21-30`
- Modify: `apps/manifold_outbound/lib/manifold/outbound.ex:231-305,529-559`
- Modify: `apps/manifold_outbound/test/manifold/outbound_test.exs`

- [ ] **Step 1: Add failing queue-routing tests**

Tests must show:

```elixir
assert {:error, %Error{reason: :send_method_required}} =
         Outbound.queue_draft(account.id, draft.id)
assert Repo.get!(OutboundMessage, draft.id).state == "draft"

assert {:ok, queued} = Outbound.queue_draft(account.id, draft.id)
submission = Repo.get_by!(ProviderSubmission, outbound_message_id: queued.id)
assert submission.send_method_id == gmail_method.id
assert submission.provider == "gmail"
assert submission.provider_rfc_message_id == "<#{queued.id}@manifold.local>"
assert submission.request_sha256 == sha256(expected_gmail_raw)
```

Also prove SMTP selection, exact sender validation, atomic rollback at the existing fault boundary, method switch after queue does not change the snapshot, and an already queued draft remains idempotent.

- [ ] **Step 2: Run and verify failure**

```sh
devenv shell -- mix test apps/manifold_outbound/test/manifold/outbound_test.exs
```

- [ ] **Step 3: Add connectors dependency and queue transaction step**

Add `{:manifold_connectors, in_umbrella: true}`. Before changing draft state, call `Connectors.enabled_send_method/1` inside a `Multi.run` and persist the selected ID/kind. Build `Envelope` from locked message/recipients, render for the provider, and calculate SHA-256 over exact bytes. Use stable `provider_rfc_message_id = "<#{message.id}@manifold.local>"` and `idempotency_expires_at` only for legacy Resend rows; new Gmail/SMTP rows must not depend on that window.

- [ ] **Step 4: Run focused outbound context tests**

```sh
devenv shell -- mix test apps/manifold_outbound/test/manifold/outbound_test.exs
```

- [ ] **Step 5: Commit**

```sh
git add apps/manifold_outbound/mix.exs apps/manifold_outbound/lib/manifold/outbound.ex \
  apps/manifold_outbound/test/manifold/outbound_test.exs
git commit -m "feat(outbound): snapshot account send methods"
```

---

### Task 8: Implement Gmail API outbound provider

**Files:**
- Create: `apps/manifold_outbound/lib/manifold/outbound/provider/gmail.ex`
- Modify: `apps/manifold_outbound/lib/manifold/outbound/provider.ex`
- Create: `apps/manifold_outbound/test/manifold/outbound/provider/gmail_test.exs`

**Interface:**

```elixir
Gmail.submit([access_token: token, base_url: url, req_options: opts], request)
# POST /gmail/v1/users/me/messages/send
# JSON %{raw: Base.url_encode64(request.raw_message, padding: false)}
```

- [ ] **Step 1: Write Req.Test protocol and error tests**

Assert bearer token, path, base64url payload, accepted `%{"id" => id, "threadId" => thread}`, 401/invalid grant reconnect classification, insufficient scope, 429 Retry-After, definite 4xx permanent, 5xx temporary, invalid response, and transport error classification.

Introduce an explicit provider error class:

```elixir
%Provider.Error{
  class: :uncertain,
  code: "acceptance_unknown",
  message: "Gmail may have accepted the message"
}
```

Use an injected request transport marker in tests to distinguish failure before request transmission (`:transient`) from failure after the request may have reached Google (`:uncertain`). Do not infer certainty from a generic timeout without phase evidence; classify unknown phase as uncertain.

- [ ] **Step 2: Run and verify failure**

```sh
devenv shell -- mix test apps/manifold_outbound/test/manifold/outbound/provider/gmail_test.exs
```

- [ ] **Step 3: Implement Gmail adapter**

Use Req with retries and redirects disabled. Return `%Provider.Submission{provider_message_id: id, metadata: %{thread_id: thread_id}}`. Sanitize provider response messages to 500 characters and never include request raw or token in errors.

- [ ] **Step 4: Run Gmail provider tests**

```sh
devenv shell -- mix test apps/manifold_outbound/test/manifold/outbound/provider/gmail_test.exs
```

- [ ] **Step 5: Commit**

```sh
git add apps/manifold_outbound/lib/manifold/outbound/provider/gmail.ex \
  apps/manifold_outbound/lib/manifold/outbound/provider.ex \
  apps/manifold_outbound/test/manifold/outbound/provider/gmail_test.exs
git commit -m "feat(outbound): submit mail through Gmail API"
```

---

### Task 9: Implement complete SMTP submission transport and adapter

**Files:**
- Modify: `apps/manifold_connectors/lib/manifold/connectors/smtp/transport.ex`
- Modify: `apps/manifold_connectors/lib/manifold/connectors/smtp/client.ex`
- Modify: `apps/manifold_connectors/lib/manifold/connectors/smtp/fake.ex`
- Modify: `apps/manifold_connectors/lib/manifold/connectors/provider.ex`
- Create: `apps/manifold_connectors/test/manifold/connectors/smtp/client_submission_test.exs`
- Create: `apps/manifold_outbound/lib/manifold/outbound/provider/smtp.ex`
- Create: `apps/manifold_outbound/test/manifold/outbound/provider/smtp_test.exs`

**Interfaces:**

```elixir
SMTP.Transport.submit(conn, %{
  envelope_from: "sender@example.net",
  recipients: ["to@example.net", "hidden@example.net"],
  raw_message: smtp_raw
})
# => {:ok, %{response: "250 ..."}}
#  | {:error, Connectors.Provider.Error.t()}
```

- [ ] **Step 1: Write failing SMTP protocol tests**

Script fake server replies and assert exact command order: `EHLO`, auth, `MAIL FROM`, every `RCPT TO`, then `DATA`, dot-stuffed CRLF body, terminator, final 250, and best-effort QUIT. Add cases for RCPT 450 temporary, RCPT 550 permanent with no DATA sent, pre-DATA disconnect temporary, and post-terminator/pre-reply disconnect uncertain.

- [ ] **Step 2: Run and verify failure**

```sh
devenv shell -- mix test apps/manifold_connectors/test/manifold/connectors/smtp/client_submission_test.exs
```

- [ ] **Step 3: Extend transport/client/fake**

Add `submit/2` to the SMTP behaviour and permit `:uncertain` in the connector Provider error class for post-acceptance-capable transports. In Client, normalize addresses against CR/LF, require every RCPT success before DATA, issue `RSET` or close on rejection, convert message line endings to CRLF, dot-stuff lines beginning with `.`, send one `\r\n.\r\n` terminator, and tag connection failures with protocol phase so ambiguity is explicit.

- [ ] **Step 4: Implement outbound SMTP adapter**

`Provider.SMTP.submit/2` connects using checked-out settings/password, calls transport `submit/2`, always quits best-effort, maps connector `temporary|permanent|reconnect` errors to outbound `transient|permanent`, and maps the connector's explicit uncertain code to outbound `:uncertain`. Generate a stable local provider message ID from the RFC Message-ID after final 250.

- [ ] **Step 5: Run SMTP connector and outbound tests**

```sh
devenv shell -- mix test apps/manifold_connectors/test/manifold/connectors/smtp \
  apps/manifold_outbound/test/manifold/outbound/provider/smtp_test.exs
```

- [ ] **Step 6: Commit**

```sh
git add apps/manifold_connectors/lib/manifold/connectors/smtp \
  apps/manifold_connectors/lib/manifold/connectors/provider.ex \
  apps/manifold_connectors/test/manifold/connectors/smtp \
  apps/manifold_outbound/lib/manifold/outbound/provider/smtp.ex \
  apps/manifold_outbound/test/manifold/outbound/provider/smtp_test.exs
git commit -m "feat(outbound): submit mail through SMTP methods"
```

---

### Task 10: Dispatch snapshotted methods and persist uncertainty safely

**Files:**
- Modify: `apps/manifold_outbound/lib/manifold/outbound/provider.ex`
- Modify: `apps/manifold_outbound/lib/manifold/outbound/provider/resend.ex`
- Modify: `apps/manifold_outbound/lib/manifold/outbound/submission.ex:21-284`
- Modify: `apps/manifold_outbound/lib/manifold/outbound/jobs/submit_outbound.ex:18-46`
- Modify: `apps/manifold_outbound/test/manifold/outbound/submission_test.exs`
- Modify: `apps/manifold_outbound/test/manifold/outbound/jobs/submit_outbound_test.exs`

- [ ] **Step 1: Write failing dispatch and state tests**

Cover Gmail/SMTP registry dispatch, checkout of the snapshotted method rather than currently enabled method, disabled/disconnected snapshot failure, re-rendered SHA mismatch, accepted provider metadata, transient retry, permanent failure, uncertain atomic transition, worker completion after uncertainty, and legacy Resend dispatch.

```elixir
assert {:error, %Provider.Error{class: :uncertain}} = Outbound.submit_message(queued.id)
message = Repo.get!(OutboundMessage, queued.id)
submission = Repo.get_by!(ProviderSubmission, outbound_message_id: queued.id)
assert message.state == "submission_uncertain"
assert submission.state == "uncertain"
refute_enqueued worker: SubmitOutbound, args: %{outbound_message_id: queued.id}
```

- [ ] **Step 2: Run and verify failure**

```sh
devenv shell -- mix test apps/manifold_outbound/test/manifold/outbound/submission_test.exs \
  apps/manifold_outbound/test/manifold/outbound/jobs/submit_outbound_test.exs
```

- [ ] **Step 3: Replace global adapter selection with registry dispatch**

For `gmail|smtp`, checkout `submission.send_method_id`, rebuild the provider-specific Request, verify SHA-256 equality, and call the mapped adapter. For `resend` rows with null `send_method_id`, use the existing runtime Resend config and adapted Request API. Remove `provider_adapter` as the default for new rows but retain explicit test injection in `opts`.

- [ ] **Step 4: Persist uncertain outcomes**

Extend `Provider.Error.class` to `:transient | :permanent | :uncertain`. Add a dedicated `persist_result` clause that locks message/submission, sets `submission_uncertain`/`uncertain`, records `last_error_class = "uncertain"`, emits one lifecycle event/telemetry outcome, and returns a permanent Core error so the worker completes without retry. Keep Resend's idempotency-expiry behavior for legacy rows only.

- [ ] **Step 5: Run full outbound tests**

```sh
devenv shell -- mix test apps/manifold_outbound/test
```

- [ ] **Step 6: Commit**

```sh
git add apps/manifold_outbound/lib/manifold/outbound/provider.ex \
  apps/manifold_outbound/lib/manifold/outbound/provider/resend.ex \
  apps/manifold_outbound/lib/manifold/outbound/submission.ex \
  apps/manifold_outbound/lib/manifold/outbound/jobs/submit_outbound.ex \
  apps/manifold_outbound/test/manifold/outbound/submission_test.exs \
  apps/manifold_outbound/test/manifold/outbound/jobs/submit_outbound_test.exs
git commit -m "feat(outbound): dispatch account send methods"
```

---

### Task 11: Add Gmail Send setup, upgrade, reconnect, and compose blocking UI

**Files:**
- Modify: `apps/manifold_web/lib/manifold_web/controllers/connector_oauth_controller.ex:9-77`
- Modify: `apps/manifold_web/lib/manifold_web/live/account_live/receive_method_new.ex:10-60,264-328`
- Modify: `apps/manifold_web/lib/manifold_web/live/account_live/send_method_new.ex:9-240`
- Modify: `apps/manifold_web/lib/manifold_web/live/account_live/show.ex:1-310`
- Modify: `apps/manifold_web/lib/manifold_web/live/mail_live/index.ex:225-245,1180-1245`
- Modify: `apps/manifold_web/test/manifold_web/account_live_test.exs`
- Modify: `apps/manifold_web/test/manifold_web/external_accounts_web_test.exs`
- Modify: `apps/manifold_web/test/manifold_web/outbound_mail_live_test.exs`

- [ ] **Step 1: Write failing settings/OAuth tests**

Assert Add Send shows Gmail and SMTP choices, unconfigured Gmail remains disabled with exact text, Gmail choice renders `purpose=send`, callback creates a send method and flashes “Gmail send method connected”, receive links include `purpose=receive`, receive-only auth shows “Upgrade Gmail access”, reconnect-required shared auth shows one reconnect action, and account IDs cannot cross-bind.

```elixir
view |> element("#send-method-gmail") |> render_click()
assert has_element?(view, ~s|a[href*="/connectors/gmail/start?account_id=#{account.id}&purpose=send"]|)
```

- [ ] **Step 2: Write failing compose test**

```elixir
view |> form("#draft-form", draft: valid_draft_params()) |> render_submit()
assert render(view) =~ "Add send method"
assert has_element?(view, ~s|a[href="/settings/accounts/#{account.id}/send_methods/new"]|)
assert Repo.get!(OutboundMessage, draft.id).state == "draft"
```

- [ ] **Step 3: Run and verify failure**

```sh
devenv shell -- mix test apps/manifold_web/test/manifold_web/account_live_test.exs \
  apps/manifold_web/test/manifold_web/external_accounts_web_test.exs \
  apps/manifold_web/test/manifold_web/outbound_mail_live_test.exs
```

- [ ] **Step 4: Implement purpose-aware controller**

Accept only `receive|send`, default legacy missing purpose to receive, pass purpose into OAuth.start, preserve it in Consumed, call purpose-aware completion, and redirect to the bound account. Use generic public errors; never render provider response detail.

- [ ] **Step 5: Implement method pickers and lifecycle copy**

Add `step: :choose_kind | :gmail_confirm | :smtp_form` to SendMethodNew. Reuse existing settings choice classes/icons and Provider-not-configured behavior. Keep SMTP async test/save. Show Upgrade/Reconnect based on shared authorization state and requested capability. Do not create persistence from LiveView events before OAuth callback or SMTP save.

- [ ] **Step 6: Handle blocked sending without losing draft**

In MailLive, match `%Core.Error{reason: :send_method_required}`, keep the saved draft assigned, show an error with the account-specific setup link, and do not navigate to Sent. Preserve current handling for other queue errors.

- [ ] **Step 7: Run scoped web tests**

```sh
devenv shell -- mix test apps/manifold_web/test/manifold_web/account_live_test.exs \
  apps/manifold_web/test/manifold_web/external_accounts_web_test.exs \
  apps/manifold_web/test/manifold_web/outbound_mail_live_test.exs
```

- [ ] **Step 8: Commit**

```sh
git add apps/manifold_web/lib/manifold_web/controllers/connector_oauth_controller.ex \
  apps/manifold_web/lib/manifold_web/live/account_live/receive_method_new.ex \
  apps/manifold_web/lib/manifold_web/live/account_live/send_method_new.ex \
  apps/manifold_web/lib/manifold_web/live/account_live/show.ex \
  apps/manifold_web/lib/manifold_web/live/mail_live/index.ex \
  apps/manifold_web/test/manifold_web/account_live_test.exs \
  apps/manifold_web/test/manifold_web/external_accounts_web_test.exs \
  apps/manifold_web/test/manifold_web/outbound_mail_live_test.exs
git commit -m "feat(web): add Gmail send method setup"
```

---

### Task 12: Add safe telemetry, ADR, operator docs, and feature reference

**Files:**
- Modify: `apps/manifold_connectors/lib/manifold/connectors/gmail_authorizations.ex`
- Modify: `apps/manifold_outbound/lib/manifold/outbound/submission.ex`
- Modify: relevant connector/outbound telemetry tests
- Create: `docs/adr/0010-account-selected-outbound-methods.md`
- Modify: `docs/adr/0007-read-only-provider-connectors.md`
- Modify: `docs/DESIGN.md`
- Modify: `README.md`
- Create: `.agents/skills/develop/references/gmail-receive-send-methods.md`

- [ ] **Step 1: Write failing telemetry metadata tests**

Attach a handler and assert OAuth upgrade/token refresh and Gmail/SMTP submission emit IDs, provider, method kind, duration/outcome/error code, while recursively rejecting keys/values containing `token`, `password`, `authorization_code`, `raw_message`, or the test message body.

- [ ] **Step 2: Run and verify failure**

```sh
devenv shell -- mix test apps/manifold_connectors/test/manifold/connectors/gmail_authorizations_test.exs \
  apps/manifold_outbound/test/manifold/outbound/submission_test.exs
```

- [ ] **Step 3: Emit sanitized events**

Use event prefixes `[:manifold, :connectors, :oauth, ...]` and existing `[:manifold, :outbound, :submit, ...]`. Metadata is limited to internal account/authorization/method/message IDs, adapter, outcome, and normalized code. Measurements contain duration/attempt count only.

- [ ] **Step 4: Write architecture and operator documentation**

ADR 0010 must record account-selected routing, shared Gmail authorization, functional SMTP, uncertainty semantics, and legacy Resend compatibility. Mark ADR 0007 as superseded only for outbound provider sending; its receive-sync read-only decision remains active. Update `docs/DESIGN.md` and README with:

```text
MANIFOLD_GMAIL_CLIENT_ID
MANIFOLD_GMAIL_CLIENT_SECRET
https://www.googleapis.com/auth/gmail.readonly
https://www.googleapis.com/auth/gmail.send
/connectors/gmail/callback
```

Document Gmail API enablement, exact HTTPS callback, test users, consent-screen scope configuration, stable encryption key, and Google verification before public use. Do not include real credentials or production endpoints.

- [ ] **Step 5: Add repository feature reference**

Create `.agents/skills/develop/references/gmail-receive-send-methods.md` with module ownership, schema/migration names, OAuth purposes, queue/uncertainty invariants, exact scoped test commands, staging smoke checklist, and explicit follow-ups (HTML/attachments, aliases, Graph send, push).

- [ ] **Step 6: Run focused tests and stale-claim scan**

```sh
devenv shell -- mix test apps/manifold_connectors/test/manifold/connectors/gmail_authorizations_test.exs \
  apps/manifold_outbound/test/manifold/outbound/submission_test.exs
rg -n "Gmail.*read-only|provider_adapter|provider: \"resend\"" README.md docs .agents/skills/develop/references apps/manifold_outbound/lib
```

Expected: tests pass; remaining read-only statements are explicitly receive-only; remaining Resend references are webhook/legacy compatibility, not new-message routing.

- [ ] **Step 7: Commit**

```sh
git add apps/manifold_connectors/lib/manifold/connectors/gmail_authorizations.ex \
  apps/manifold_outbound/lib/manifold/outbound/submission.ex \
  apps/manifold_connectors/test apps/manifold_outbound/test \
  docs/adr/0010-account-selected-outbound-methods.md docs/adr/0007-read-only-provider-connectors.md \
  docs/DESIGN.md README.md .agents/skills/develop/references/gmail-receive-send-methods.md
git commit -m "docs: record account-selected Gmail and SMTP delivery"
```

---

### Task 13: Run scoped regression, migration, and staging verification

**Files:**
- Modify only files already in scope if a scoped check exposes a defect directly caused by this feature.
- Do not fix unrelated test failures; report them and stop per repository PRD scope rules.

- [ ] **Step 1: Format changed Elixir files**

```sh
devenv shell -- mix format
devenv shell -- mix format --check-formatted
```

Expected: both exit 0.

- [ ] **Step 2: Compile strictly**

```sh
devenv shell -- mix compile --warnings-as-errors
```

Expected: exit 0 with no warnings.

- [ ] **Step 3: Run scoped application suites**

```sh
devenv shell -- mix test apps/manifold_connectors/test
devenv shell -- mix test apps/manifold_outbound/test
devenv shell -- mix test apps/manifold_web/test/manifold_web/account_live_test.exs \
  apps/manifold_web/test/manifold_web/external_accounts_web_test.exs \
  apps/manifold_web/test/manifold_web/outbound_mail_live_test.exs
```

Expected: all in-scope suites pass.

- [ ] **Step 4: Verify migration on realistic existing rows**

Create test/dev fixtures for one existing Gmail receive connector, one Microsoft connector, one IMAP connector, one SMTP method, and one queued Resend submission before applying migration. Run:

```sh
devenv shell -- mix ecto.migrate
```

Verify Gmail tokens decrypt under the shared authorization ID, Microsoft/IMAP rows are unchanged, SMTP becomes selectable, and legacy Resend submission still completes with a fake provider.

- [ ] **Step 5: Run Gmail/SMTP staging smoke checklist when credentials are available**

1. Connect two distinct Gmail identities to two matching Manifold accounts.
2. Receive a message into each and verify isolation.
3. Add Gmail Send incrementally to each.
4. Send from each and verify the correct Gmail Sent mailbox.
5. Send once through a configured SMTP account.
6. Confirm an account without a method keeps its draft and shows **Add send method**.
7. Simulate an ambiguous fake transport failure and confirm no automatic resend job exists.

If real credentials are unavailable, record the smoke check as pending external verification; do not fabricate a pass.

- [ ] **Step 6: Inspect final scope and history**

```sh
git status --short
git diff main...HEAD --stat
git log --oneline main..HEAD
```

Expected: only spec-scoped source/tests/migration/docs changed; commits are task-sized and conventional.

- [ ] **Step 7: Commit verification-only corrections if needed**

If formatting or an in-scope verification correction changed files, the isolated worktree contains only this feature, so stage the scoped roots explicitly:

```sh
if ! git diff --quiet; then
  git add -- apps/manifold_connectors apps/manifold_outbound apps/manifold_web \
    apps/manifold_data/priv/repo/migrations/20260811000100_add_shared_gmail_authorizations.exs \
    docs/adr/0007-read-only-provider-connectors.md \
    docs/adr/0010-account-selected-outbound-methods.md docs/DESIGN.md README.md \
    .agents/skills/develop/references/gmail-receive-send-methods.md
  git commit -m "test: verify Gmail and SMTP account delivery"
fi
```

If no files changed, do not create an empty commit.
