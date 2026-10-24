# Gaoxy HTTP server migration

- Date: 2026-10-22.
- Status: current dependency refresh selects published Gaoxy 0.12.1 in
  `codex/dependency-refresh-20261022`; all 1,635 tests across 17 apps, strict
  dev/test/prod compilation, assets and both fresh releases' HTTP startup pass.
  Original 0.9.0 implementation (`631cd7c`) and subsequent 0.11.0 maintenance
  (`bd46de3`) and this refresh (`60eb5af`) are merged into `main` as of
  2026-10-24, with no target deployment. Historical acceptance remains below. See [dependency maintenance](dependency-maintenance.md).
- Scope: Web/API Phoenix listeners and the Edge signed HTTP API. Remove all
  three direct Bandit dependencies; preserve SMTP and provider HTTP transports.

## Ownership

- `apps/manifold_web/mix.exs`, `apps/manifold_api/mix.exs`,
  `apps/manifold_edge/mix.exs`: `gaoxy_http ~> 0.12.1`.
- Root `mix.exs`: `websock_adapter ~> 0.12.1` using the
  `gaoxy_websock_adapter` Hex distribution and `override: true`. The OTP
  application name remains `websock_adapter`; do not install both distributions.
- `config/config.exs`: `Gaoxy.PhoenixAdapter`, a 64 MiB Web byte budget and a
  16 MiB API budget. Web retains the previous 10,000,000-byte WebSockAdapter
  frame capacity; API accommodates Plug's 8,000,000-byte parser and its copies.
  Environment layers retain existing binding, port and enable settings.
  Endpoints continue owning listeners under their supervisors.
- `apps/manifold_edge/lib/manifold/edge/application.ex`: `Gaoxy.HTTP`,
  `id: :edge_api`, existing Router and bind/port parsing. The service budget is
  `max(4 MiB, 4 * max_request_bytes)`; the native body ceiling is
  `max(8 MiB, max_request_bytes + 1)` so the Router owns its JSON 413 response.
- `test/support/http_wire.exs`: test-only TCP/HTTP/WebSocket helpers shared by
  real consumer gates in the three owning apps' test trees.
- `docs/DEPLOYMENT.md`: reverse proxy and operator-visible transport limits.

## Contracts and limits

Keep cookie sessions, CSRF/Origin checks, LiveView WebSocket and longpoll,
development code reload, static assets/HEAD, JSON APIs, webhook original bytes,
attachment chunking/closed-client cleanup, Edge signed method/path/Host/body,
duplicate-header/replay rejection and private raw-file delivery.

The public service byte budgets accommodate Plug aggregation and its flattened
copy. They do not replace the 8,000,000-byte default parser limit, 1,048,576-byte
webhook limit or 2,097,152-byte default Edge limit, and do not bound total BEAM
memory. Edge derives its transport budgets from the configured request limit
at startup. Do not lower application limits to fit server defaults.

Plain TCP defaults to HTTP/1; Caddy terminates public HTTPS. Gaoxy's finite HTTP
deadline is 30 seconds with 5-second header/read/write limits. The unchanged
Phoenix socket receives WebSockAdapter's 10,000,000-byte frame ceiling;
Gaoxy 0.9.0 makes an omitted message ceiling follow it. Both are clamped to
one quarter of the service byte budget, so Web needs at least 40,000,000 bytes
plus accounting headroom. Its selected 64 MiB budget preserves that ceiling;
the earlier 16 MiB budget wrongly rejected a real 5 MiB ASCII composer event.
WebSock retains 60-second idle and 24-hour lifetime limits. Application tests must
exercise actual sockets: ConnTest and LiveViewTest bypass server adapters.

## Verification

### Current Gaoxy 0.12.1 refresh checkpoint

Gaoxy 0.12.1 requires public `http_core >= 0.21.16`; the paired HTTP/TLS/QUIC
cohort is 0.21.16. DuskMoon tooling remains 10.0.2 and UI advances to 10.0.11.
The full umbrella passes **1,635 tests**, zero failures, across 17 apps in one
invocation, seed 42. Strict dev/test/prod compilation, formatting, npm frozen
installation and verification (330 packages), development/production assets,
Hex direct/all audits and npm workspace audits pass. npm audit reports zero
vulnerabilities; JavaScript checks report zero errors and two existing warnings.

Both fresh production releases pass actual local HTTP startup: Web HTML, API
health and signed Edge status return 200. Packaged/runtime Gaoxy is 0.12.1;
the six included HTTP/TLS applications are 0.21.16. Mix is unavailable and
Bandit/ThousandIsland are absent. Release closures contain 81 applications for
main and 43 for Edge; these are packaged counts, not started application counts.
The runtime helper starts 15 main roots after 38 migrations, and four Edge
roots after one migration. Both VMs exit zero and the two disposable databases
are removed. Current smoke report:
`tmp/gaoxy-release-smoke/run_1792682683_1ed5f51d/report.json`.
See [dependency maintenance](dependency-maintenance.md) for detailed commands,
artifacts and cleanup verification. No target deployment was performed.

The published upgrade preserves existing listener limits, adapter identity and
shutdown budgets. HEAD now preserves application Content-Length metadata; the
exact Phoenix administrative disconnect reason closes normally. The new
`request_timeout: :infinity` option is not selected: Manifold retains its finite
HTTP request policy. Native H2 now uses public HTTP Core HPACK; no H2 listener
is enabled by this refresh.

### Historical Gaoxy 0.11.0 maintenance checkpoint

All 17 applications pass **1,635 tests**, seed 42, in two isolated groups:
nonserver 1,378 and Web/API/Edge 257. The server counts remain API 8, Web 207,
Edge 42, including the larger composer and active Edge shutdown regressions.
Strict dev/test/prod compilation, formatter and rebuilt production assets pass.

Fresh main/Edge production releases at
`tmp/dependency-maintenance-2026-10-22/releases/{manifold,manifold_edge}` pass
actual Web HTML, API health and signed Edge status HTTP requests. Their packaged
and runtime Gaoxy cohorts are 0.11.0 and included HTTP/TLS packages 0.21.15.
Bandit/ThousandIsland were absent at that checkpoint. Historical smoke report:
`tmp/gaoxy-release-smoke/run_1792645325_02405e7e/report.json`.
See [dependency maintenance](dependency-maintenance.md) for the complete upgrade,
validation and npm proxy-feature exception. The historical evidence below
belongs to the original 0.9.0 acceptance.

### Original Gaoxy 0.9.0 acceptance

Run from the umbrella root under `devenv shell`:

```sh
MIX_ENV=test mix deps.get
mix test apps/manifold_web/test apps/manifold_api/test apps/manifold_edge/test --seed 42
mix compile --warnings-as-errors
```

Use isolated databases for independent worktrees. The implementation run uses
the root devenv environment, unsets `TEST_DATABASE_URL`, and sets
`MIX_TEST_PARTITION=_gaoxy_server`. Provide frontend assets first (CI uses
`mix assets.deploy`); the isolated worktree copied the primary checkout's
generated static artifacts because no asset sources changed.

Baseline: API 6, nested Web tests 182, Edge 31 passed, seed 42; the initial Web
selection omitted the root-level file containing 16 more existing tests.
Initial isolated setup
attempts found missing Styx sources, copied obsolete optional-app build metadata
and a missing generated static manifest. Fetch dependencies for `MIX_ENV=test`,
prune unused build artifacts in the isolated tree and supply assets before
interpreting those setup failures as application regressions.

The new API selection gate failed on Bandit. After selecting Gaoxy, a real
7,999,999-byte GraphQL JSON POST returned 400 with the default 1 MiB service
budget; configuring the public 16 MiB budget made both API wire tests pass.
The initial combined run passed 255 tests before independent review expanded
the composer gate beyond 256 KiB and added an active Edge drain gate.

Original Gaoxy **0.9.0** scoped acceptance, seed 42: **257 tests, zero failures**.
API 8/8, Web 207/207 (198 existing and 9 new cases), Edge 42/42 (31 existing
and 11 new). HTTP client/TLS packages were 0.21.10 at this acceptance checkpoint;
current dependency versions and new verification are tracked in the maintenance record.

| Status | Consumer gate | Evidence |
| --- | --- | --- |
| PASS | Actual HTTP and discovery | Both Endpoint adapters/server_info, API health/GraphQL, browser session/static/HEAD |
| PASS | Ordinary LiveView traffic | Real WebSocket join/filter/leave and longpoll join/event; the earlier 64 KiB composer also passed |
| PASS | Larger composer events | 300 KiB quote-text body (about 0.9 MiB form input, 1.8 MiB escaped render) and 5 MiB ASCII body; exact wire render, persisted bytes and HTTP reload/WebSocket rejoin |
| PASS | Webhook and parser boundaries | Raw-byte signatures/tamper, exactly 1 MiB webhook and oversize 413; 7,999,999-byte GraphQL JSON |
| PASS | Attachment streaming | Exact chunked bytes, source IO close acknowledgement, actual TCP reset followed by IO close and process DOWN |
| PASS | Edge HTTP/auth/storage | IPv4/IPv6, signed raw path/method/Host/body, replay/duplicate rejection, private raw file, disabled and idle shutdown |
| PASS | Edge request limits | Exactly 2,097,152 bytes and configured 8,388,609 bytes accepted; next byte returns application JSON 413 |
| PASS | Edge active shutdown | Real 100 Continue and public active count gate an admitted request; progressing upload drains with a normal `:shutdown` instance exit |
| PASS | Build hygiene | Changed-file formatting, `git diff --check`, test and production compilation with `--warnings-as-errors` |
| PASS | Packaged runtime | Fresh main/Edge production releases; full root applications started without Mix; Web HTML, API health and signed Edge status return 200; Gaoxy 0.9.0 present and Bandit/ThousandIsland absent |
| NOT RUN | Deployment | Reverse-proxy/TLS and target-host acceptance; no deployment requested |

Both local production releases were assembled at version 0.6.8, then exercised
through their installed `bin/<release> eval` command, production runtime config
and complete root application closures. Main started 15 roots with an
82-application release closure,
ran 38 migrations and served `/contacts` HTML and `/api/v1/health` JSON. Edge
started four roots with a 44-application release closure, ran one migration and served a real signed
`/api/v1/status` request; its SMTP application also started on loopback port zero.
Both release manifests, packaged libraries and started applications omit Bandit
and ThousandIsland. Each runtime Gaoxy cohort reports 0.9.0, and Mix is unavailable.

Local evidence is retained under
`tmp/gaoxy-release-smoke/run_1792625119_1f82adc1/`: `report.json`,
`cleanup-audit.json`, and `main/release.log` / `edge/release.log`. Both VMs exited
with code zero; all three HTTP ports closed. PostgreSQL independently confirmed
that all four disposable databases created across the three smoke attempts were
removed. These ignored task artifacts use synthetic configuration and loopback
listeners; they do not establish reverse-proxy/TLS or credentialed-provider
acceptance.

The first smoke attempt encountered multiple historical release manifests. The
probe was corrected to select `RELEASE_VSN`. The second found obsolete Bandit
files retained by an earlier `mix release --overwrite`; old output directories
were preserved under `tmp/gaoxy-release-smoke/stale-releases-1792625084/`, and
both releases were assembled into fresh destinations before the passing run.
Failed reports remain under `run_1792624938_615080fb/` and
`run_1792625022_4c95334f/`. These were probe/artifact setup failures, not new
production defects. For dependency-removal checks, use a fresh release output
directory rather than assuming `--overwrite` removes obsolete libraries.

Independent final review found no actionable issues. Whitespace and all 156
local Markdown targets/anchors in the six changed documents pass.
No full-umbrella tests, production deployment, publication, push or merge were
performed for this migration acceptance. The original checkout remains unchanged. Candidate
worktree: `.trees/gaoxy-http-server`.

## Historical blockers, resolved in 0.9.0

- **Web:** [gsmlg-dev/gaoxy#9](https://github.com/gsmlg-dev/gaoxy/issues/9),
  linked to the same underlying defect in #6. Gaoxy 0.7.0 independently capped
  messages at 256 KiB, while Phoenix rejected `max_message_size` as an unknown
  socket option. In 0.9.0 the omitted message limit follows Phoenix's accepted
  frame setting. Both composer cases now reach persistence and reconnect checks
  with the original socket/session declarations.
- **Edge:** [gsmlg-dev/gaoxy#10](https://github.com/gsmlg-dev/gaoxy/issues/10).
  In 0.7.0 `Gaoxy.HTTP.child_spec/1` defaulted to a 5-second parent shutdown
  budget, shorter than the instance's drain plus cleanup headroom. The 0.9.0
  HTTP child spec uses the validated core budget (7 seconds by default), and
  the existing active-request regression passes without a local override.

Both issues were type **Bug**, label **internal request**, severity **blocker**;
they are now closed and identify release 0.9.0, source
`ed3fbbfbe4016906b10a97711193d341f3d9ed4f`. Prior checkpoint: **256 tests,
254 passed, 2 failed**, with WebSocket close 1009 and Edge instance `:killed`
after 5002 ms during a progressing upload. Those failures caused the migration
to stop. Published dependencies were updated before work resumed; resolved
callsite TODO markers have been removed. No dependency patch, reduced
application body limit or local shutdown override was used.

## Upstream policy

Use the published cohort and its
[versioned Phoenix guide](https://github.com/gsmlg-dev/gaoxy/blob/v0.9.0/docs/phoenix.md).
Route reproduced dependency defects upstream with `internal request`, issue
type and callsite marker per AGENTS.md. Stop an affected blocker path without
a local transport workaround. Publication and production deployment require
their own authorization and evidence.
