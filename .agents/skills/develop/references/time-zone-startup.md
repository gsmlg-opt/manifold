# Shared time-zone database startup

- Date: 2026-10-21.
- Scope: make the globally configured time-zone provider available before shared-core consumers start; release v0.6.7. No mail, calendar data, schema or provider behavior changes.
- Status: source repair and scoped regression verification complete. Candidate and published artifact acceptance are subsequent release gates, tracked in the v0.6.7 GitHub release notes.

## Ownership and failure

`config/config.exs` globally selects `Tzdata.TimeZoneDatabase` and disables automatic tzdata updates. `manifold_core` is a runtime dependency of both `manifold_data` and Edge. Calendars previously supplied the only tzdata dependency, so the main release could start Data/Oban before tzdata, and Edge omitted the global provider.

Default-entrypoint cold starts of the published v0.6.5 and v0.6.6 main images failed with Oban `DateTime.add/4` reporting `time_zone_not_found`. The same fresh-VM calculation succeeded after starting tzdata, confirming a startup dependency problem. Prior failure evidence is retained under `/tmp/manifold-v066-image-verification/`; those temporary files are not release assets.

## Implementation boundary

Declare tzdata as a runtime dependency of `apps/manifold_core/mix.exs`, using the existing `~> 1.2` constraint and lockfile selection. Keep the calendars dependency because its modules use tzdata directly. OTP application dependencies enforce initialization before core, Data/Oban and Edge start. No imperative startup calls, entrypoint wrappers, release-order overrides, new secrets or migrations are needed.

## Acceptance

- Start only core in a fresh Elixir VM with the configured global provider, without Mix starting umbrella applications. UTC arithmetic and an Asia/Shanghai conversion must succeed; tzdata must start before core while Data and Calendars remain stopped.
- Run existing core tests, Data configuration tests and Edge tests, scoped formatting and strict test compilation. Preserve lockfiles.
- Before publication, build both candidate images with the repository Dockerfile and the release workflow's version substitution, then migrate disposable databases and start the default entrypoints. Require main page/API/assets and live Repo/Oban/time-zone checks, plus Edge signed status and replay rejection.
- Publish through the existing release workflow, verify both archive checksums/active versions and packaged startup dependencies, all six image tags, embedded metadata and the same isolated default-entrypoint cold starts. Artifact outcomes belong in the GitHub release notes.

## Operational limits

The v0.6.6 startup failure remains a historical failure even after this repair. No public production deployment, provider writes or target-mail acceptance is included. HTML fidelity and binary attachment encoding remain separate follow-ups.

## Source verification checkpoint

- Baseline: core 41, Data configuration 14 and Edge 31 tests, seed 243443; 86 tests, zero failures.
- RED: the new [fresh-VM startup regression](../../../../apps/manifold_core/test/manifold/core/time_zone_startup_test.exs), seed 555614, failed with the expected `DateTime.add/4` / `time_zone_not_found` on the old graph.
- GREEN: the one-line core dependency repair passed the same fresh-VM regression, UTC arithmetic and Asia/Shanghai conversion. Seed 114609: core 42, Data configuration 14 and Edge 31; **87 tests, zero failures**. Strict test compilation passed; both lockfiles are unchanged.
- Temporary logs: `/tmp/manifold-v067-{baseline,red,green}.log`. These are local evidence, not packaged release assets. No tests outside the scoped set were run locally at this checkpoint.
