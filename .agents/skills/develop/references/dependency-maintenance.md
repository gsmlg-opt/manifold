# Hex and npm dependency maintenance

- Date: 2026-10-22.
- Status: dependency upgrade and local validation passed on the isolated branch.
- Scope: umbrella dependency declarations/locks, web workspace manifests/lock,
  necessary consumer compatibility, and scoped tests/documentation.

## Current checkpoint: 2026-10-22

The Gaoxy server migration was committed separately as `631cd7c` before this
maintenance update on `codex/gaoxy-http-server`. Started with the requested
`mix hex.outdated` and `bunx npm-check-updates -w` in the original root's
Devenv environment, then updated public constraints, ran `mix deps.update --all`
and `bunx npm-check-updates -w -u` in the isolated worktree.

The Hex lock updates 28 entries, with no dependency source patches or new
overrides. The existing Gaoxy WebSockAdapter alias remains required.

| Dependency group | Previous | Updated |
| --- | --- | --- |
| Gaoxy / gaoxy_http / gaoxy_websock_adapter | 0.9.0 | 0.11.0 |
| Fetch / HTTP / TLS / QUIC cohort | 0.21.10 | 0.21.15 |
| Phoenix | 1.8.15 | 1.8.16 |
| LiveView | 1.2.12 | 1.2.13 |
| Phoenix DuskMoon UI, Hex and npm | 9.16.7 | 10.0.10 |
| DuskMoon bundler/runtime/native/npm tooling | 9.16.16 | 10.0.2 |
| Codepagex | 0.1.13 | 0.2.0 |
| html_sanitize_ex | 1.5.5 | 1.5.6 |
| Decimal | 3.1.1 | 3.2.0 |
| npm marked | 18.1.0 | 18.1.1 |
| npm @duskmoon-dev/core | 1.20.4 | 1.20.7 |

Other Hex updates are Castore 1.0.22, mdex_mermaid 0.4.0 and mdex_native 0.2.12.
The new UI dependency permits mdex_mermaid 0.4.0; no indirect override is used.
Styx, Rrule, Ecto/Postgrex, Rustler and Tailwind declarations remain unchanged.

Compatibility review of the published packages found:

- DuskMoon 10 extracts repository-local build tools into published packages;
  Manifold already consumes those packages. Its removed `dm_git_*` components
  are unused here, and the npm `phoenix_duskmoon/hooks` export remains public.
- Gaoxy 0.11 retains the 0.9 WebSock/parser behavior and validated child shutdown
  budget. Existing Web 64 MiB / API 16 MiB and dynamic Edge budgets are retained;
  no new listener backend options are required.
- Codepagex 0.2 corrects `:ascii` to standard US-ASCII, preserving apostrophes
  and backticks. A consumer regression covers both `ascii` and `us-ascii` mail.
  Our replacement callback does not exercise its changed error-return contract.
- HTTP/TLS/QUIC pins move together. Preserve fresh HTTP/1 connections, OTP TLS
  default, explicit ex_ssl failure, secret-safe errors, disabled replay and
  provider-owned retry/uncertain-submission behavior.

### npm installation and upstream follow-up

Canonical `mix npm.install` and one retry failed with
`npm dependency prefetch failed: :timeout`. Direct registry access timed out;
the same request through the configured proxy succeeded. The NPM client's
public configuration cannot select or forward a proxy. Its resolver/HTTP client
code is unchanged from 9.16.16, so this is not evidence of a new resolver or
HTTPFetch defect. [duskmoon-bundler#4](https://github.com/duskmoon-dev/duskmoon-bundler/issues/4)
tracks proxy configuration as a Feature with severity `needed`.

For this proxy-required environment, the following standard npm workflow
regenerated the lock and installed its frozen contents without dependency
patches or overrides. The `assets.setup` alias retains the canonical installer.

```sh
# WORKAROUND(upstream): duskmoon-dev/duskmoon-bundler#4
npm install --package-lock-only
npm ci
mix npm.verify
npm audit --json
bunx npm-check-updates -w
```

All five commands passed: verification reports 330 installed packages, audit
reports zero vulnerabilities, and both npm manifests are current. Standard npm
regenerated the lock layout (332 entries including workspace/root records);
direct Core 1.20.7 and UI's nested Core 1.20.6 remain valid. Lock SHA-256:
`db3b6bcc28b35663e9c81d28bc8aff660867e4819caa7b554cf5f7fe44dc0ed6`.
Canonical installation remains failed in this environment; do not record it as
passing. Remove this workaround after the upstream feature is released and
verified with the repository's npm workflow.

### Validation

All commands used the original root's Devenv environment and the isolated
`.trees/gaoxy-http-server` worktree. Tests unset `TEST_DATABASE_URL` and use
`MIX_TEST_PARTITION=_gaoxy_server`, seed 42. All 17 application test directories
were covered in two invocations, with no exclusions:

- PASS: 14 nonserver applications, **1,378 tests, zero failures**, including
  core 42, connectors 735, outbound 179 and mail 90 (the new ASCII regression).
- PASS: Web 207, API 8 and Edge 42, **257 tests, zero failures**, including
  actual HTTP/WebSocket/longpoll, large composer and active drain gates.
- Total: **1,635 tests, zero failures**.
- PASS: strict development, test and production compilation; repository
  `mix format --check-formatted` and `git diff --check`.
- PASS: all 168 local Markdown targets/anchors across the nine changed documents.
- PASS: JS check, zero errors and two existing unused catch-parameter warnings;
  development and production `mix assets.deploy` rebuilt/digested CSS and JS.
- PASS: final `mix hex.outdated` and `mix hex.outdated --all`, both exit zero
  with all direct/transitive packages current. Final `bunx npm-check-updates -w`
  also reports both manifests current; npm audit reports zero vulnerabilities.
- PASS: both production releases assembled at application version 0.6.8 in
  fresh `tmp/dependency-maintenance-2026-10-22/releases/{manifold,manifold_edge}`
  destinations, preserving the previously validated 0.9.0 outputs.
- PASS: fresh packaged startup with Mix unavailable and synthetic config.
  Main starts 15 roots with an 82-application release closure, runs 38 migrations
  and serves Web HTML/API health 200. Edge starts four roots with a
  44-application release closure, runs one
  migration and serves signed status 200 with no pending deliveries. Both
  packaged/runtime Gaoxy cohorts are 0.11.0; each release's six included HTTP/TLS
  packages are 0.21.15. Optional EventSource/WebSocket packages are not required.

Packaged smoke evidence: `tmp/gaoxy-release-smoke/run_1792645325_02405e7e/`.
Independent audit confirms no Bandit/ThousandIsland, ExUnit or test-helper
artifacts in either release. Both VMs exited zero, all three HTTP ports closed,
and PostgreSQL independently confirmed both disposable databases were removed;
`cleanup-audit.json` records these checks. No warning/error entries were logged.
No merge, push, publication, target deployment or credentialed provider staging
is included. Other ignored task evidence is stored under
`tmp/dependency-maintenance-2026-10-22/` in the worktree. Canonical `mix npm.install`
is the explicit failed check tracked by upstream #4; the supported standard npm
lock/frozen install and canonical read-only verification passed instead.

## Historical checkpoint: 2026-10-09

The following records the earlier maintenance release. Its HTTP migration
follow-up was superseded by the completed native-client migration described in
[the current client contract](../../../../docs/HTTP_CLIENT.md).

### Dependency updates

Started with the requested `mix hex.outdated` and
`bunx npm-check-updates@latest -w` in Devenv, then updated compatible Hex
packages and ran `bunx npm-check-updates@latest -w -u`.

| Direct dependency | Previous | Updated |
| --- | --- | --- |
| absinthe | 1.11.0 | 1.12.0 |
| duskmoon_bundler / duskmoon_bundler_runtime / phoenix_duskmoon | 9.12.1 | 9.16.7 |
| lazy_html | 0.1.12 | 0.1.13 |
| oban | 2.23.1 | 2.24.1 |
| phoenix | 1.8.12 | 1.8.15 |
| phoenix_live_view | 1.2.10 | 1.2.12 |
| phoenix_pubsub | 2.2.0 | 2.4.1 |
| req | 0.7.3 | 0.7.5 |
| ex_ssl | unavailable Git pin | exact Hex 0.17.1 |
| npm marked | 18.0.10 | 18.1.0 |
| npm @duskmoon-dev/core | 1.18.1 | 1.20.4 |
| npm phoenix_duskmoon | 9.12.1 | 9.16.7 |

Transitive updates include Finch 0.24.0, Mint 1.11.0, mdex 0.14.2 and the
DuskMoon runtime/native packages. DuskMoon npm/QuickBEAM now bring in Fetch
0.17.1 and its matching runtime/protocol packages. The previous Git ex_ssl spec
conflicted with the required Hex ex_ssl package; an exact release pin avoids
an incompatible override. See `tls-backends.md` and `docs/TLS_BACKENDS.md` for
published-source protocol/public-API/OTP/OpenSSL acceptance.

Post-update `mix hex.outdated --all` lists only `mdex_mermaid 0.3.6 -> 0.4.0` as
unavailable under the dependency requirements. Keep that indirect constraint;
do not override it just to make the audit empty. Exit status 1 reports the
remaining available upstream version, rather than a failed registry check.

### Consumer compatibility and module ownership

- `manifold_outbound`: Oban 2.24 snooze now rolls back job attempt, retains
  max_attempts and counts snoozes in job meta. Update the Microsoft 429 worker
  test to that contract while explicitly checking the real provider attempt.
  Submission attempt limits remain owned by persisted ProviderSubmission state;
  no production retry policy changed.
- `manifold_web`: DuskMoon Card/Tooltip rendering contracts changed. Preserve
  account-action and mail-action accessibility by forwarding the new tooltip
  trigger attrs at all seven callsites; update assertions to the new semantic
  markup and verify their associations across mail state changes.
- `manifold_connectors`: exact published ex_ssl dependency and an upstream TODO
  at the Gmail HTTP callsite; application HTTP defaults remain Req/current
  specialized transports.
- Other apps: dependency graph validation only; no schema/migration, credential,
  environment variable, protocol-default or production-account changes.

### Installation and verification notes

Canonical npm installation is `mix npm.install`. New `mix npm.verify` detected
pre-existing web-local node_modules shadowing the root installation; use the
supported `mix npm.rebuild` to remove generated root/workspace installs and
restore the root lock. `mix npm.ci` plus `mix npm.verify` then passed for 192
packages. The package-lock SHA-256 remained
`28450ce845ff52c3fa44f3a72fe43716c7b0537704902a919cdc99a49f4f6ae5`.
Rebuild assets after removing shadowing so assets use the current packages.

Initial umbrella regression exposed obsolete Oban assertions and DuskMoon
consumer/markup changes. Do not count that initial run as passing; the final
run must verify the compatibility edits.

### HTTP client follow-up

See `http-client-migration.md` for the seven owning paths, native-client versus
Req-adapter choices, and required real-wire acceptance. Default-client migration
still fails the secret-safe telemetry requirement with installed Fetch 0.17.1.
[http_fetch#31](https://github.com/gsmlg-dev/http_fetch/issues/31) is closed upstream
as of 2026-10-10; the consumer dependency update, independent verification and
migration design approval remain pending. No default switch was implemented.

### Validation

The following checks were completed on 2026-10-09 before iCloud integration.

- PASS: mandatory Manifold TLS scope, 46 tests.
- PASS: independent actual-Hex ex_ssl protocol/public API/OTP/OpenSSL gate,
  430 tests/properties with no skipped or excluded tests, local OTP 28 only.
- PASS: Microsoft submission worker scoped file, 18 tests.
- PASS: final strict development/test compilation and repository formatting.
- PASS: npm frozen installation and verification, and rebuilt CSS/JS assets.
- PASS with warnings: JavaScript check, 0 errors and 2 existing unused catch
  parameter warnings in app.js.
- NOT RUN: credentialed provider staging or browser interaction verification.
- PASS: full umbrella regression, `mix test --seed 456954`, 1,256 tests across
  15 apps, 0 failures.
- PASS: after the final two mail-tooltip callsite changes, full web regression,
  `mix test apps/manifold_web/test --seed 456954`, 155 tests, 0 failures.
- PASS: final direct Hex and npm workspace audits list all direct dependencies
  at their latest versions; `git diff --check` is clean.
- Release integration on 2026-10-10: 84 account/mail/OAuth/Oban scoped tests
  passed (seed 521982); npm verification matches the frozen lock (192 packages).
  These changes are included in the authorized v0.5.1 maintenance release.
