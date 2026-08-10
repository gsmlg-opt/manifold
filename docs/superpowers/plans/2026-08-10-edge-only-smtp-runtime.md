# Edge-only SMTP Runtime Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop the main Manifold mail-client runtime from starting an inbound SMTP listener while preserving inbound SMTP in the separate `manifold_edge` release.

**Architecture:** Treat `manifold_smtp` as an edge-owned runtime capability. The application remains in the umbrella for compilation and focused tests, but its listener is disabled by default; edge runtime configuration explicitly enables it, and only the edge release includes it as a permanent application.

**Tech Stack:** Elixir 1.18, OTP applications/releases, Mix configuration, ExUnit, devenv

---

## File map

- `apps/manifold_data/test/manifold/config_test.exs`: proves release membership and role-specific SMTP enablement.
- `mix.exs`: removes `manifold_smtp` from the main release while retaining it in `manifold_edge`.
- `config/config.exs`: makes the umbrella/default SMTP application inert.
- `config/runtime.exs`: enables the listener only for the edge role/release.
- `devenv.nix`: removes main-runtime inbound SMTP listener variables.
- `apps/manifold_web/lib/mix/tasks/manifold.run.ex`: describes the mail-client development boot accurately.
- `README.md`: documents main runtime and edge-only inbound SMTP accurately.
- `.agents/skills/develop/references/edge-only-smtp-runtime.md`: records ownership, configuration, validation, and follow-up guidance.

### Task 1: Prove and change release composition

**Files:**
- Modify: `apps/manifold_data/test/manifold/config_test.exs`
- Modify: `mix.exs:67-90`

- [ ] **Step 1: Write the failing release-composition test**

Add this test after the existing connectors release-composition test:

```elixir
test "inbound SMTP ships only in the edge release" do
  releases = Manifold.Umbrella.MixProject.project()[:releases]
  local_apps = releases[:manifold][:applications]
  edge_apps = releases[:manifold_edge][:applications]

  refute Keyword.has_key?(local_apps, :manifold_smtp)
  assert edge_apps[:manifold_smtp] == :permanent
end
```

- [ ] **Step 2: Run the test and verify the expected failure**

Run:

```sh
mix test apps/manifold_data/test/manifold/config_test.exs:58
```

Expected: FAIL because the main release currently contains `manifold_smtp: :permanent`; the edge assertion passes.

- [ ] **Step 3: Remove SMTP from the main release only**

Delete this entry from the `manifold` release application list in `mix.exs`:

```elixir
manifold_smtp: :permanent,
```

Leave the identical entry in the `manifold_edge` application list unchanged.

- [ ] **Step 4: Run the focused release-composition tests**

Run:

```sh
mix test apps/manifold_data/test/manifold/config_test.exs
```

Expected: all configuration tests pass.

- [ ] **Step 5: Commit the release boundary**

```sh
git add apps/manifold_data/test/manifold/config_test.exs mix.exs
git commit -m "fix(runtime): reserve inbound SMTP for edge release"
```

### Task 2: Make SMTP listener enablement role-specific

**Files:**
- Modify: `apps/manifold_data/test/manifold/config_test.exs`
- Modify: `config/config.exs:94-113`
- Modify: `config/runtime.exs:154-174`

- [ ] **Step 1: Write the failing default configuration test**

Add:

```elixir
test "default runtime disables the inbound SMTP listener" do
  smtp = read_config(:dev)[:manifold_smtp]

  refute smtp[:enabled]
end
```

- [ ] **Step 2: Run the default test and verify the expected failure**

Run:

```sh
mix test apps/manifold_data/test/manifold/config_test.exs
```

Expected: one failure because `config/config.exs` currently sets `enabled: true`
in development.

- [ ] **Step 3: Write the failing edge runtime test**

Add:

```elixir
test "edge runtime enables the inbound SMTP listener" do
  put_runtime_env(%{
    "RELEASE_NAME" => "manifold_edge",
    "MANIFOLD_EDGE_DATABASE_URL" => "ecto://localhost/manifold_edge",
    "MANIFOLD_EDGE_API_URL" => "https://edge.example",
    "MANIFOLD_EDGE_SHARED_SECRET" => String.duplicate("e", 32),
    "MANIFOLD_EDGE_INSTALLATION_ID" => "edge-1"
  })

  smtp = read_runtime(:prod)[:manifold_smtp]

  assert smtp[:enabled]
end
```

- [ ] **Step 4: Run the edge test and verify the expected failure**

Run:

```sh
mix test apps/manifold_data/test/manifold/config_test.exs
```

Expected: two failures: the default remains enabled, and edge runtime
configuration overrides resolver and ingest but does not set `enabled: true`.

- [ ] **Step 5: Implement the minimal role-specific configuration**

Change the shared SMTP default in `config/config.exs` to:

```elixir
config :manifold_smtp,
  enabled: false,
```

Extend the existing edge-only override in `config/runtime.exs` to:

```elixir
config :manifold_smtp,
  enabled: true,
  resolver: Manifold.Edge.SMTP,
  ingest: Manifold.Edge.SMTP
```

- [ ] **Step 6: Run the full focused configuration test file**

```sh
mix test apps/manifold_data/test/manifold/config_test.exs
```

Expected: all tests pass, including default-disabled and edge-enabled assertions.

- [ ] **Step 7: Commit the runtime configuration**

```sh
git add apps/manifold_data/test/manifold/config_test.exs config/config.exs config/runtime.exs
git commit -m "fix(runtime): enable SMTP listener only at edge"
```

### Task 3: Remove main-runtime SMTP startup claims

**Files:**
- Modify: `devenv.nix:9-11`
- Modify: `apps/manifold_web/lib/mix/tasks/manifold.run.ex:2-18`
- Modify: `README.md:1-20`
- Modify: `README.md:232-243`

- [ ] **Step 1: Remove inbound SMTP variables from devenv**

Delete these three main-runtime environment settings from `devenv.nix`:

```nix
env.MANIFOLD_SMTP_HOSTNAME = "localhost";
env.MANIFOLD_SMTP_BIND = "127.0.0.1";
env.MANIFOLD_SMTP_PORT = "2525";
```

Keep spool and raw-store variables because connector imports still use the durable ingest pipeline.

- [ ] **Step 2: Correct the development Mix task documentation**

Replace the module documentation and short description with:

```elixir
@moduledoc """
Starts the Manifold development server.

Always runs `mix compile --force` first, then delegates to `mix phx.server`,
which starts the Phoenix endpoint and the mail-client umbrella applications.
"""

@shortdoc "Force-compiles and starts the Manifold mail-client runtime"
```

The task implementation remains unchanged.

- [ ] **Step 3: Correct README runtime descriptions**

Replace the opening product description with:

```markdown
Manifold is a self-hosted Phoenix webmail application backed by an Elixir-native
mail platform. The main runtime acts as a mail client for provider-hosted
accounts; the optional `manifold_edge` release provides durable inbound SMTP for
installations that deploy it.
```

Replace the current development-listener capability bullet with:

```markdown
- Edge-only `gen_smtp` listener, using port `2525` in development and port `25`
  in the edge release by default.
```

Replace the development startup wording with:

````markdown
Start the mail-client runtime:

```sh
devenv processes start
```

The managed Manifold process runs pending Ecto migrations after PostgreSQL is
ready and before starting the application.

Open Phoenix at `http://localhost:4290`; the API listens at
`http://localhost:4292`. The separate `manifold_edge` release owns inbound SMTP.
````

Preserve the existing edge deployment section and its port `25` documentation.

- [ ] **Step 4: Check formatting and stale main-runtime claims**

```sh
mix format --check-formatted apps/manifold_web/lib/mix/tasks/manifold.run.ex
nix-instantiate --parse devenv.nix >/dev/null
rg -n "Start Phoenix and the SMTP listener|Submit SMTP mail to `127\\.0\\.0\\.1:2525`|starts Phoenix and the Manifold SMTP listener" README.md apps/manifold_web/lib/mix/tasks/manifold.run.ex
```

Expected: formatting and Nix parsing exit 0 and `rg` returns no matches.

- [ ] **Step 5: Commit development and README updates**

```sh
git add devenv.nix apps/manifold_web/lib/mix/tasks/manifold.run.ex README.md
git commit -m "docs(runtime): describe edge-only inbound SMTP"
```

### Task 4: Record repository development guidance

**Files:**
- Create: `.agents/skills/develop/references/edge-only-smtp-runtime.md`
- Add: `docs/superpowers/plans/2026-08-10-edge-only-smtp-runtime.md`

- [ ] **Step 1: Add the feature reference**

Create the file with:

```markdown
# Edge-only SMTP Runtime

## Feature

- **Date**: 2026-08-10
- **Status**: done
- **Scope**: main and edge OTP release/runtime composition

## Ownership and behavior

- `manifold` is the mail-client runtime and does not include or enable inbound SMTP.
- `manifold_edge` includes `manifold_smtp` permanently and enables its listener through edge runtime configuration.
- `manifold_smtp` remains in the umbrella for edge compilation and focused tests; its default supervisor is inert.
- `Manifold.Connectors.SMTP.Client` is outbound client functionality and is independent of the inbound listener.

## Configuration impact

- Shared configuration sets `config :manifold_smtp, enabled: false`.
- Edge runtime configuration sets `enabled: true` with `Manifold.Edge.SMTP` as resolver and ingest adapter.
- There is no main-runtime SMTP enable environment variable.

## Validation

- `mix test apps/manifold_data/test/manifold/config_test.exs`
- `mix test apps/manifold_smtp/test`
- `mix test apps/manifold_connectors/test/manifold/connectors/smtp_send_method_test.exs`
- `mix format --check-formatted`
- Restart normal devenv runtime and verify ports `4290` and `4292` respond while `2525` is closed.

## Follow-ups

- Keep future inbound SMTP changes scoped to `manifold_edge` unless the product runtime boundary is explicitly revised.
```

- [ ] **Step 2: Verify and commit the reference**

```sh
mix format --check-formatted
git diff --check
git add .agents/skills/develop/references/edge-only-smtp-runtime.md docs/superpowers/plans/2026-08-10-edge-only-smtp-runtime.md
git commit -m "docs: record edge-only SMTP runtime boundary"
```

Expected: both checks exit 0 and the commit contains only the feature reference
and its approved implementation plan.

### Task 5: Verify tests, compilation, release metadata, and live runtime

**Files:**
- Verify only; no expected source changes.

- [ ] **Step 1: Run scoped ExUnit tests**

```sh
mix test apps/manifold_data/test/manifold/config_test.exs
mix test apps/manifold_smtp/test
mix test apps/manifold_connectors/test/manifold/connectors/smtp_send_method_test.exs
```

Expected: every command exits 0 with zero failures.

- [ ] **Step 2: Run strict static checks**

```sh
mix format --check-formatted
mix compile --warnings-as-errors
git diff --check
```

Expected: every command exits 0 without warnings or whitespace errors.

- [ ] **Step 3: Verify release metadata directly**

```sh
mix run --no-start -e '
releases = Manifold.Umbrella.MixProject.project()[:releases]
main = releases[:manifold][:applications]
edge = releases[:manifold_edge][:applications]
unless not Keyword.has_key?(main, :manifold_smtp) and edge[:manifold_smtp] == :permanent,
  do: System.halt(1)
'
```

Expected: exit 0 with no output.

- [ ] **Step 4: Restart and verify the normal development runtime**

```sh
devenv processes restart manifold
devenv processes wait
devenv processes status manifold
curl -fsS -o /dev/null -w 'web=%{http_code}\n' http://127.0.0.1:4290/
curl -fsS -o /dev/null -w 'api=%{http_code}\n' http://127.0.0.1:4292/.well-known/manifold
if ss -ltn | rg -q ':2525\\b'; then exit 1; fi
```

Expected: Manifold is `ready`, web and API return HTTP `200`, and no TCP listener owns port `2525`.

- [ ] **Step 5: Inspect final scope**

```sh
git status --short --branch
git log --oneline --decorate -6
```

Expected: only the pre-existing untracked `docs/superpowers/plans/2026-08-10-smtp-form-style.md` remains untracked; implementation commits are on the current branch and no unrelated files changed.
