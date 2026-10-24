# Gaoxy HTTP Server Implementation Plan

> **For agentic workers:** Use subagent-driven-development for independent
> Phoenix and Edge test work, with the parent owning dependencies/config/docs.

**Original goal:** Serve Web, API and Edge with published Gaoxy 0.9.0 and remove direct
Bandit dependencies without changing application transport contracts.

**Architecture:** Phoenix Endpoints own their Gaoxy listeners. Edge directly
supervises Gaoxy.HTTP around its existing Router. Caddy still terminates TLS.

**Original tech stack:** Elixir 1.18 / OTP 28, Phoenix 1.8, LiveView 1.2, Gaoxy 0.9.0.

**Original status:** committed as `631cd7c`; implementation and local acceptance
**PASS**, 257 tests with zero failures. Published
0.9.0 resolves [LiveView message capacity](https://github.com/gsmlg-dev/gaoxy/issues/9)
and [active Edge drain](https://github.com/gsmlg-dev/gaoxy/issues/10); both packaged
releases passed local startup and actual HTTP smoke. The original implementation
and subsequent maintenance (`bd46de3`) are now merged into `main`. No local
dependency workaround or target deployment. Current evidence is in the
[maintenance record](../../../.agents/skills/develop/references/http-server-migration.md).

**Current dependency checkpoint:** Gaoxy 0.12.1, HTTP/TLS 0.21.16, DuskMoon
tooling 10.0.2 and UI 10.0.11. All 1,635 tests across 17 apps pass in one
invocation, seed 42; strict dev/test/prod compilation, formatting, Hex/npm
audits, development/production assets and both fresh releases' actual
Web/API/signed Edge HTTP startup pass. Packaged/runtime versions match the
selected cohorts, with Mix and Bandit/ThousandIsland absent. This refresh
is merged into `main` as `60eb5af` (2026-10-24), with no target deployment. The preceding Gaoxy 0.11.0 / HTTP/TLS 0.21.15 / UI
10.0.10 checkpoint passed all 1,635 tests across 17 applications, including the
same 257 server gates, strict production compilation, assets and both fresh
releases' actual HTTP startup. Version-specific validation and the npm proxy
feature follow-up are tracked separately in
[dependency maintenance](../../../.agents/skills/develop/references/dependency-maintenance.md).
The checklist below preserves the original 0.9.0 acceptance.

## 1. Baseline and regression gates

- [x] Fetch the baseline lockfile dependencies and run the selected existing
  tests under the root devenv with `TEST_DATABASE_URL` unset and
  `MIX_TEST_PARTITION=_gaoxy_server`: API 6, nested Web 182, Edge 31 passed.
  The initial Web selection omitted 16 root-level tests; final validation
  includes the entire scoped test directories.
- [x] Add real Phoenix HTTP/WebSocket tests in the Web/API test trees. Start
  listeners on port zero, discover their ports, use actual TCP requests and
  explicit protocol replies for synchronization, and clean up owned listeners.
  Cover LiveView join/event, longpoll, static/HEAD, API JSON, webhook signature
  bytes/413 and attachment transfer/closed-client cleanup.
- [x] Add real Edge listener tests in its test tree. Cover signed requests,
  authority, replay/duplicate headers, body limit and raw send_file. Assert the
  server is application-owned so the test fails if Edge still starts Bandit.
- [x] Observe the new Gaoxy selection gates fail on the original integration.

## 2. Minimal integration

Parent-owned files: `apps/manifold_{web,api,edge}/mix.exs`, root `mix.exs`,
`mix.lock`, `config/config.exs`. Edge worker owns
`apps/manifold_edge/lib/manifold/edge/application.ex` and Edge listener tests.
Phoenix worker owns new Web/API listener tests and their test-only helpers.

- [x] Replace each direct Bandit dependency with
  `{:gaoxy_http, "~> 0.9.0"}`. Declare the shared override once in root deps:
  `{:websock_adapter, "~> 0.9.0", hex: :gaoxy_websock_adapter, override: true}`.
- [x] Set `adapter: Gaoxy.PhoenixAdapter` for both Endpoints.
- [x] Replace Edge's Bandit child with
  `{Gaoxy.HTTP, id: :edge_api, plug: {Manifold.Edge.Router, []}, ip: parse_bind(...), port: ...}`.
- [x] Resolve dependencies, prune only obsolete unlocked dependencies and
  inspect the lockfile diff. Preserve HTTP client/TLS package versions.
- [x] Run the new transport gates and fix task-owned implementation/test
  issues. Route the two reproduced dependency defects upstream with Bug type,
  internal request label, blocker severity and callsite TODO markers.
- [x] Obtain published upstream fixes, update dependencies and pass the larger
  composer and active Edge drain gates. Remove resolved callsite TODO markers.
- [x] Preserve the original WebSocket frame capacity with a 64 MiB Web budget;
  retain the 16 MiB API budget and derive Edge budgets from its request limit.
  Reproduce the 5 MiB composer rejection on the earlier 16 MiB Web budget and
  verify exact rendering, persistence and reconnect after the adjustment.

## 3. Validation and documentation

- [x] Preserve the initial 0.7.0 checkpoint: 256 tests, 254 passed and 2 upstream
  failures, seed 42. Published fixes were required before resuming.
- [x] Pass all scoped suites after updating the fixed dependency: API 8,
  Web 207, Edge 42; total **257 tests, zero failures**, seed 42. Format changed
  Elixir files and strictly compile test and production environments.
- [x] Assemble both main and Edge production releases.
- [x] Verify main/Edge release closures and packaged startup with isolated
  databases and loopback listeners. Web HTML, API health and signed Edge status
  return 200; both runtime cohorts are 0.9.0, with Mix unavailable and no
  Bandit/ThousandIsland in manifests, libraries or started applications.
  Use fresh release destinations; `--overwrite` retained obsolete artifacts.
  Both VMs exit zero, HTTP ports close and disposable databases are removed.
- [x] Update `docs/DEPLOYMENT.md`, `docs/PROGRESS.md`, `docs/superpowers/README.md` and
  `.agents/skills/develop/references/http-server-migration.md` with final scope,
  dependencies, consumer gates, limits and independently checkable results.
- [x] Independently review the complete diff for scope compliance and correctness. Leave
  changes reviewable on `codex/gaoxy-http-server`; do not publish or deploy.
- [x] Check final whitespace and all 156 local Markdown links/anchors.
