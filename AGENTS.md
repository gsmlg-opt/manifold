# Repository Guidelines

## Project Structure & Module Organization

This is an Elixir umbrella app under the root `apps/` directory. Domain boundaries are `manifold_core`, `manifold_data`, `manifold_accounts`, `manifold_connectors`, `manifold_mail`, `manifold_smtp`, `manifold_security`, `manifold_outbound`, `manifold_cloud`, `manifold_edge`, `manifold_ingest`, `manifold_storage`, `manifold_web`, and `manifold_api`.

Code lives in `apps/<app>/lib`, tests in `apps/<app>/test`, and migration/schema changes go in `apps/manifold_data/priv/repo`. Frontend assets are in `apps/manifold_web/assets` and `apps/manifold_web/lib`. Environment and releases are configured in `config/`, `Dockerfile`, and `devenv.nix`.

## Build, Test, and Development Commands

Use `devenv shell` first for dependencies and consistent toolchains.

- `mix setup` — install dependencies, create/migrate DB, and install frontend deps.
- `mix ecto.setup` / `mix ecto.migrate` / `mix ecto.reset` — manage database lifecycle.
- `mix assets.build` — build CSS/JS bundles for local work.
- `MIX_ENV=prod mix assets.deploy` — digest and deploy production assets.
- `devenv processes start` — run local Postgres plus umbrella services (managed by this repo’s process definitions).
- `mix test` — run full ExUnit suite.
- `mix format --check-formatted` — check formatter output.
- `mix compile --warnings-as-errors` — compile with strict warnings.
- `mix duskmoon_bundler.js.check` — JS sanity check used in CI.

## Coding Style & Naming Conventions

- Use existing project style: 2-space indentation and standard Elixir formatting via `mix format`.
- Modules: `PascalCase` (e.g., `Manifold.Accounts`), files/functions: `snake_case`.
- Keep app boundaries strict: shared schemas/data contracts in `manifold_data`, transport/protocol logic in `manifold_mail`/`manifold_smtp`, API/Web surfaces in their dedicated apps.
- Run `mix format` on changed files before opening PRs.

## Web UI Design

`manifold_web` styling is constrained by [`DESIGN.md`](DESIGN.md): phoenix_duskmoon tokens only, themes `sunshine` / `moonlight`, appbar on `primary`, theme switcher persistence. Do not hardcode hex/Tailwind palette colors for app chrome. Product/architecture design remains in [`docs/DESIGN.md`](docs/DESIGN.md).

## Testing Guidelines

Testing is ExUnit-based. Keep tests beside code in each app’s `test/` directory and name them as `*_test.exs`.

- Broad check: `mix test`
- App-focused check: `mix test apps/<app>/test`
- Prefer deterministic tests and explicit assertions around persistence, queueing, and connector flows.

## Commit & Pull Request Guidelines

Follow the repo’s observed commit style: short conventional prefixes such as `feat:`, `fix:`, `chore:`, `ci:`, `test:` and imperative summaries.

For PRs, include:
- Clear scope summary and linked issue/ADR if relevant.
- Commands run (`mix test`, `mix format --check-formatted`, etc.).
- Notes on migration impact and any environment-variable changes.
- UI/API behavior changes with minimal reproduction steps where behavior is not obvious.

## Security & Configuration Tips

Treat non-OAuth secrets as required production inputs in local shell files and
CI: `MANIFOLD_CONNECTOR_ENCRYPTION_KEY`, `RESEND_API_KEY`, and DB/env keys in
`config/runtime.exs`. Google and Microsoft OAuth client credentials are managed
only through Settings at `/settings/oauth`; do not put them in environment files
or CI variables.

Do not commit real secrets. Keep other local credentials in untracked env files and never paste production endpoints in public bug reports.

## Skill and Feature Documentation Rule

When adding or updating a feature, also update this repository skill index entry:
`.agents/skills/develop/references/{name}.md` (historically sometimes written as
`.agents/skills/devlop/references/{name}.md`). Keep it current with implementation
notes, module ownership, and any task-level follow-ups.
