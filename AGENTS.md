# AGENTS.md

Actionable guidance for AI coding agents working in the Manifold repository.

Canonical product and architecture detail lives in `docs/DESIGN.md`, ADRs under `docs/adr/`, and crash recovery contracts in `docs/CRASH_BOUNDARIES.md`. Prefer those documents when this file and implementation disagree on intent; prefer the code and migrations when they disagree on current behavior.

---

## 1. Project Overview & Intent

Manifold is a **self-hosted Phoenix webmail application** backed by an Elixir-native mail platform. The browser LiveView UI is the primary mail client for locally hosted mailboxes. It accepts inbound SMTP, durably stores raw RFC 5322 messages, projects mailbox views asynchronously, submits outbound mail through a **managed HTTPS provider** (not direct MX), and optionally imports read-only Gmail / Microsoft 365 mail into local mailboxes.

### Architecture

- **Phoenix umbrella monolith** with explicit OTP application boundaries (not microservices).
- **Single primary OTP release** (`manifold`) plus an optional separate **edge ingress release** (`manifold_edge`).
- **PostgreSQL + Ecto** for metadata; **Oban** for durable jobs; **local filesystem** spool and raw-object store.
- **Functional core, supervised effects**: pure transforms for addresses, routes, state transitions, and policy; processes only for lifecycle, concurrency, scheduling, or resource ownership.
- **Raw message is the immutable source of truth**; parsed headers/bodies/search/threads are rebuildable projections.
- **Durable acceptance before SMTP `250`**: ready spool rename → PostgreSQL accept transaction → transactional Oban archival job.
- UI: Phoenix LiveView + **phoenix_duskmoon** / Duskmoon Bundler (no separate SPA).
- Local API: versioned REST + GraphQL on a separate Phoenix Endpoint (`API_PORT`, default `4292`).

Milestones 0–6 are implemented. Out of scope unless explicitly requested: IMAP/POP3/JMAP, direct outbound MX, rich-text compose, outbound attachments, provider mailbox mutation/send, Gmail watch / Graph subscriptions, bundled spam/malware engines, application-level user auth.

---

## 2. Quick Start / Local Environment

Primary local environment is **Nix flakes + devenv** (not Docker-first).

### Toolchain (devenv)

- Elixir (OTP 28 / Elixir ~> 1.18; CI uses Elixir `1.18.4`)
- Node.js 24 (assets)
- PostgreSQL 16

```sh
devenv shell
```

### First-time setup

```sh
# Terminal A — Postgres
devenv processes start postgres

# Terminal B — deps, migrate, seeds, npm
devenv shell -- mix setup
```

`mix setup` runs `deps.get`, `ecto.setup` (create/migrate/seeds), and `assets.setup` (`npm.install`).

Optional connector OAuth secrets: copy `.env.example` → `.env` (never commit `.env`). Devenv sources `.env` automatically.

### Run the app

```sh
devenv processes start
# or: devenv shell -- manifold-server
```

- Web UI: `http://localhost:4290`
- SMTP (dev): `127.0.0.1:2525`
- API: port `4292` (`API_PORT`)
- Seed mailbox: `inbox@example.test` on domain `example.test`

There is **no application login**; anyone who can reach the endpoint has full access. Restrict via host networking or reverse proxy.

### Tests, format, compile

```sh
mix format --check-formatted
mix compile --warnings-as-errors
mix test

# Combined local gate (also: mix test.all)
mix test.all
```

JS check used in CI:

```sh
mix duskmoon_bundler.js.check
```

Assets:

```sh
mix assets.build
MIX_ENV=prod mix assets.deploy
```

Migrations only: `mix ecto.migrate` (centralized under `apps/manifold_data/priv/repo/migrations/`).

Helper scripts in devenv: `manifold-setup`, `manifold-migrate`, `manifold-test`, `manifold-server`.

### Releases

```sh
MIX_ENV=prod mix assets.deploy
MIX_ENV=prod mix release manifold
MIX_ENV=prod mix release manifold_edge
```

---

## 3. Repository Structure & Key Directories

```text
manifold/
├── apps/
│   ├── manifold_core/         # Pure types: address, domain, Error, IDs, state helpers
│   ├── manifold_data/         # Repo, Oban, centralized migrations, seeds
│   ├── manifold_accounts/     # Domains, mailboxes, aliases, recipient resolution
│   ├── manifold_storage/      # Spool bundles + raw/attachment object store
│   ├── manifold_ingest/       # Acceptance boundary, delivery lifecycle, archival jobs
│   ├── manifold_smtp/         # Inbound SMTP edge (gen_smtp behind Manifold modules)
│   ├── manifold_mail/         # MIME projection, folders, threads, search, sanitization
│   ├── manifold_security/     # SPF/DKIM/DMARC/malware/spam adapters + quarantine policy
│   ├── manifold_outbound/     # Managed provider submit + webhooks (Resend adapter)
│   ├── manifold_cloud/        # Local pull client for optional cloud edge
│   ├── manifold_edge/         # Standalone edge release (ingress-only)
│   ├── manifold_connectors/   # Read-only Gmail / Microsoft Graph sync + OAuth
│   ├── manifold_web/          # Phoenix LiveView UI, webhooks, OAuth callbacks
│   └── manifold_api/          # REST / GraphQL machine API endpoint
├── config/                    # Shared umbrella config (config/dev/test/prod/runtime)
├── docs/                      # DESIGN.md, CRASH_BOUNDARIES.md, milestone plans, adr/
├── test/                      # Umbrella-level tests (if any)
├── flake.nix / devenv.nix     # Reproducible shell + Postgres + process model
├── mix.exs                    # Umbrella, aliases, releases
└── .env.example               # Connector / secret checklist (no real secrets)
```

### Where things live

| Concern | Location |
| --- | --- |
| Domain policy / pure logic | `apps/manifold_core`, owning app contexts |
| Schemas | Owning app under `lib/`; migrations only in `manifold_data` |
| Oban workers | Owning app (ingest, mail, security, outbound, cloud, connectors) |
| LiveViews / HEEx | `apps/manifold_web/lib/manifold_web/live/` |
| UI components | `apps/manifold_web/lib/manifold_web/components/` |
| Frontend assets | `apps/manifold_web/assets/` (Duskmoon Bundler + Tailwind) |
| Spool / raw store (dev) | `priv/spool/dev`, `priv/raw_store/dev` (paths from env) |
| Design ADRs | `docs/adr/` |

### Dependency tiers (no cycles)

```text
Tier 0:  manifold_core
Tier 1:  manifold_data, manifold_storage, manifold_smtp
Tier 2:  manifold_accounts, manifold_mail
Tier 3:  manifold_security, manifold_outbound
Tier 4:  manifold_ingest
Tier 5:  manifold_cloud, manifold_connectors
Tier 6:  manifold_web, manifold_api

Edge release: manifold_edge -> core + storage + smtp
```

`manifold_smtp` has **no production** dependency on Accounts/Ingest/Edge; those are configured at the release boundary. Web/API call **public context APIs only**—never another app’s private schema modules.

---

## 4. Agent Guidelines & Code Conventions

### Language / framework rules

- **Elixir ~> 1.18**, `warnings_as_errors` in `:dev` and `:test`.
- Prefer **tagged tuples** and `%Manifold.Core.Error{}` for expected failures; do not raise for normal control flow.
- Primary/foreign keys: **`:binary_id`**; timestamps **UTC**.
- Use **Oban** for anything that must survive crashes; PubSub is notification-only, never the source of truth.
- Keep SMTP / protocol edges **thin**: no MIME parse, HTML sanitize, search index, security scan, or provider HTTP inside the SMTP session.
- Security adapters that are disabled must persist **`not_evaluated`**—never invent a successful auth/scan result.
- Connectors are **read-only**: import via `Manifold.Ingest.import_external/3` (or the documented public ingest API). Do not invent SMTP peer/HELO/envelope facts for provider imports; do not create `DeliveryRecipient` when no SMTP transaction occurred.
- Outbound: **managed provider HTTPS only**. Never add direct Internet SMTP / MX delivery.
- UI: prefer **phoenix_duskmoon** patterns already used in LiveViews; keep compose plain-text unless scope explicitly expands.
- Assets: Duskmoon Bundler owns JS/CSS/Tailwind—do not introduce a parallel SPA toolchain.

### File naming & formatting

- Follow existing app namespaces (`Manifold.*`, `ManifoldWeb.*`).
- Format with `mix format` (Phoenix LiveView HTMLFormatter + DuskmoonBundler.Formatter). HEEx and `apps/manifold_web/assets/**/*.{js,ts,jsx,tsx}` are included.
- New migrations: timestamped files under `apps/manifold_data/priv/repo/migrations/` only.
- Tests co-located per app under `apps/<app>/test/`. Mirror lib module paths.

### Error handling & logging

- Classify with `Manifold.Core.Error` (`:permanent` | `:temporary` | `:capacity`) and stable `reason` atoms.
- Map SMTP/API outcomes from classified errors (e.g. unknown recipient → `550 5.1.1`; temporary DB → `451`).
- Prefer Telemetry events for operational signals; keep logs free of secrets (tokens, OAuth verifiers, webhook signing secrets, encryption keys).
- Idempotent retries: key async work by immutable delivery / submission IDs; use DB constraints and explicit state machines over in-memory locks.

### Documentation when changing behavior

- Material architecture or protocol changes: update `docs/DESIGN.md` and/or add/revise an ADR.
- Crash/recovery semantics: update `docs/CRASH_BOUNDARIES.md` and add/adjust crash-boundary tests.
- Operator-facing setup: keep `README.md` and `.env.example` aligned.

---

## 5. Safety Constraints & Anti-Patterns

### Strictly avoid

1. **Direct outbound MX / Internet SMTP delivery** (ADR 0004).
2. **Returning SMTP `250` before** durable ready spool + DB accept + transactional archival job (ADR 0002).
3. **Hard-deleting “duplicates”** solely by `Message-ID` or content hash.
4. **Treating parsed MIME as more authoritative** than raw bytes + envelope metadata (ADR 0005).
5. **Dependency cycles** or Web/API reaching into another app’s private Ecto schemas.
6. **Wrapping pure contexts in GenServers** “to be more OTP.”
7. **Fabricating successful** SPF/DKIM/DMARC/malware/spam results when adapters are off.
8. **Provider write scopes** (`Mail.ReadWrite`, `Mail.Send`, Gmail mutation) or using connectors as outbound providers.
9. **Committing secrets**: `.env`, API keys, OAuth client secrets, `MANIFOLD_CONNECTOR_ENCRYPTION_KEY`, edge shared secrets, Resend keys.
10. **Sender-controlled values in filesystem paths** (spool/object keys must be server-generated IDs/digests).
11. **Synchronous heavy work** in SMTP session or LiveView mount that belongs in Oban.
12. **Docker-first** or inventing a second frontend stack without an explicit product decision.
13. **Broad drive-by refactors**, unrelated formatting, or expanding milestone scope (IMAP, rich compose, etc.) without being asked.
14. **Edge calling into the local installation**; local always pulls. Edge is ingress-only.

### Keep changes scoped

- Touch only apps and docs required for the task.
- Prefer extending existing behaviours/adapters over new parallel abstractions.
- Match naming, error shapes, and Oban job patterns already used in the owning app.
- After substantive edits: run `mix format`, then the narrowest relevant `mix test` path; before claiming done on cross-cutting work, run `mix test.all` or the CI equivalent (`format`, `compile --warnings-as-errors`, `mix test`, JS check).

### Auth / trust model reminder

Release 0.1 trusts the **deployment network boundary**. Do not assume missing login is a bug unless the task is explicitly to add authentication.
```
