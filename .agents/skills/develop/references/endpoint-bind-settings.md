# Main endpoint bind settings

- Date: 2026-10-24.
- Status: done.
- Request: [manifold#4](https://github.com/gsmlg-opt/manifold/issues/4), host-network
  deployments behind Caddy need loopback listeners without editing the release.

## Scope and ownership

- `config/runtime.exs`: main production Web/API listener configuration.
- `apps/manifold_core/test/manifold/core/endpoint_bind_config_test.exs`: isolated
  runtime configuration regression coverage; reads config without starting
  applications, servers or databases.
- `docs/DEPLOYMENT.md`: operator settings and network-mode examples.
- `manifold_web` and `manifold_api` own their respective Phoenix endpoints;
  `manifold_core` owns the shared runtime configuration regression test.
- No database, schema, provider, background-job, authentication, Edge or SMTP
  behavior changes. Other umbrella app boundaries are unchanged.

## Runtime contract

`MANIFOLD_WEB_BIND` and `MANIFOLD_API_BIND` independently select the production
main endpoint addresses. Both default to `0.0.0.0`. Values must be numeric IPv4
or IPv6 addresses accepted by `:inet.parse_strict_address/1`; no DNS resolution
occurs. Hostnames, URLs, brackets, port suffixes, abbreviated IPv4 and empty
values fail configuration loading with the variable name in an `ArgumentError`.

`PORT` and `API_PORT` still select the independent ports. `PHX_HOST` retains its
public URL meaning (HTTPS/443). Dev/test settings and the Edge release ignore
these main production variables.

A host-network deployment or installed release can set both variables to
`127.0.0.1` for a proxy on the same host. Bridge containers should retain the
wildcard default so published ports and other containers can reach listeners.
IPv6 addresses require corresponding host network support. These settings do
not add access control; existing trusted-network/proxy requirements apply.

The change stays in runtime configuration because the listener adapter already
accepts IP tuples. No new module or dependency is needed. Roll back by unsetting
the variables to restore wildcard listeners; old releases ignore the variables.

## Validation

- Initial focused regression: 8 tests, 6 expected failures before implementation.
- `mix test --no-start apps/manifold_core/test/manifold/core/endpoint_bind_config_test.exs --seed 42`:
  8 tests passed after implementation; then added Edge-release isolation coverage.
- Final focused coverage: 9 tests passed, including Edge-release isolation, in
  `tmp/issue-4/config-tests.log` before the separate data app helper ran.
- Parent verification: the 9 focused tests pass independently. A fresh test
  database (`manifold_test_issue4_release_20261024`, verified absent first)
  passes all 1,644 tests across 17 applications with seed 42, after frontend
  frozen installation and asset deployment. `TEST_DATABASE_URL` was unset;
  `POSTGRES_TEST_DB` and `MIX_TEST_PARTITION` explicitly select this owned database.
  Evidence: root `tmp/release-v0.6.9/local-regression/`.
- `mix format --check-formatted`, `mix compile --warnings-as-errors`,
  `MIX_ENV=test mix compile --warnings-as-errors` and
  `MIX_ENV=prod mix compile --warnings-as-errors`: passed.
- An additional existing `apps/manifold_data/test/manifold/config_test.exs` check
  could not run: its helper starts the data app and migrates the existing test
  database even with `--no-start`, then fails with Postgrex `ERROR 42703
  (undefined_column) column r.sent_generation does not exist`. No migration
  repair or database cleanup was attempted. This is outside the bind-setting
  scope. Evidence lives under ignored `tmp/issue-4/`.
- No JS files changed, so asset/JS checks are outside this issue's scope.

## Follow-ups

The release owner performs packaged-release checks and target deployment
acceptance. No upstream issues or temporary workarounds were needed.
