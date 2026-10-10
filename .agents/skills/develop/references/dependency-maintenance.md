# Hex and npm dependency maintenance

- Date: 2026-10-09.
- Status: dependency maintenance complete; HTTP default-client migration
  awaits a compatible dependency update, independent verification and design approval.
- Scope: umbrella dependency declarations/locks, web workspace manifests/lock,
  necessary consumer compatibility, and scoped tests/documentation.

## Dependency updates

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

## Consumer compatibility and module ownership

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

## Installation and verification notes

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

## HTTP client follow-up

See `http-client-migration.md` for the seven owning paths, native-client versus
Req-adapter choices, and required real-wire acceptance. Default-client migration
still fails the secret-safe telemetry requirement with installed Fetch 0.17.1.
[http_fetch#31](https://github.com/gsmlg-dev/http_fetch/issues/31) is closed upstream
as of 2026-10-10; the consumer dependency update, independent verification and
migration design approval remain pending. No default switch was implemented.

## Validation

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
