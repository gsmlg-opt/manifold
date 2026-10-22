# Business HTTP clients

Business consumers use native Hex `http_fetch 0.21.16` through
`Manifold.Core.HTTPClient`. Gmail/Graph connector and OAuth requests,
Gmail/Graph/Resend submission, signed cloud ingress, DAV and EAS use this shared
client. The initial 2026-10-15 migration for the v0.6.4 release candidate was
developed from `1d150fc` on `codex/http-fetch-client` and accepted on 0.21.10,
including the response-version fix for #121. The 2026-10-22 maintenance candidate
updates dependencies without changing client or provider policies.

| Consumer | Worktree transport | Remaining requirement |
| --- | --- | --- |
| Connector Gmail/Graph and OAuth | Native Fetch | Credentialed provider staging remains separate |
| Outbound Gmail/Graph/Resend | Native Fetch | Credentialed sending and delivery remain separate |
| Cloud.Client | Native Fetch, lazy raw delivery stream | Real deployed edge acceptance remains separate |
| DAV / iCloud | Native Fetch; obsolete MintAdapter removed | Credentialed Apple acceptance remains separate |
| EAS | Native Fetch, explicit TLS backend | Credentialed provider staging remains separate |

Upstream [#114](https://github.com/gsmlg-dev/http_fetch/issues/114),
[#115](https://github.com/gsmlg-dev/http_fetch/issues/115) and
[#121](https://github.com/gsmlg-dev/http_fetch/issues/121) are closed. Published
0.21.10 contains the response-version fix (upstream PR #124) and the HTTP/1
activation-cancellation fix (PR #125). Actual TLS rejection gates cover both
OTP/ex_ssl backends and textual HTTP/0.9/HTTP/2.0 responses. No local response
parser or upstream workaround is needed.
The independent [ex_ssl certificate-path issue #113](https://github.com/gsmlg-dev/http_fetch/issues/113)
concerns TLS backend selection, not default OTP HTTP migration.

## Core contract

`HTTPClient.request/1` and `post/1` return `{:ok, %HTTPClient.Response{}}` or
`{:error, %HTTPClient.TransportError{}}`. Request JSON/form/query and bearer/basic
auth are encoded explicitly. Response headers and trailers are maps of value
lists. Default decoding handles ordinary content encoding and JSON; explicit
`decode_body: false` preserves exact response bytes. Unknown options fail before
network activity. Existing `:req_options` configuration containers remain, with
Fetch-compatible options and the new test-only injection seam.

All requests use fresh HTTP/1 connections, manual redirects, disabled Fetch
telemetry and no automatic transport replay. OTP TLS remains default; explicitly
selected ex_ssl does not fall back on failure. Provider admission, cooldown,
Retry-After, idempotency and submission policy remain in their owning modules.
Errors use constant safe messages and normalized reasons, without credentials,
request headers or URLs. A timeout with no proof of pre-transmission remains an
uncertain submission, including a native DNS deadline.

Buffered responses have a default 64 MiB raw/decompressed body limit. Gmail RAW
JSON, Graph MIME and cloud raw delivery bypass this generic cap to preserve the
existing downstream MIME/spool limit and permanent oversize classification;
base64 JSON overhead does not reduce the configured import size. Header
limits default to 64 KiB and 1,000 fields. Graph outbound uses a 32 KiB header
limit and retains at most 64 KiB of the body while counting all raw bytes in
`response.private.raw_body_size`; only status 202 with zero raw bytes is accepted.

Cloud raw deliveries return a single-use lazy Enumerable with acknowledged
chunks. Enumeration starts after the headers return; truncated streams raise a
safe transport error. Early halt, explicit `HTTPClient.cancel(response)` and the
total request deadline release the stream. Cloud cancels rejected status bodies
before returning its classified error. Raw streaming allows an unbounded response
at this boundary; downstream ingestion enforces spool constraints.

Cleanup uses Fetch's logical request-completion barrier when supported. ex_ssl
uses stream termination because that barrier is unsupported for its backend.
Neither signal certifies native memory reclamation.

## DAV and EAS policy

DAV preserves exact XML bytes, valid extension method tokens (including binary
case), Basic credentials, redirect refusal, an 8 MiB body cap and a 15-second
total deadline. Initial headers and trailers share a 64 KiB / 1,000-field cap;
trailing ETags remain visible in the returned header map.

EAS retains HTTPS, forced peer verification, explicit backend/profile selection,
OPTIONS/POST, Basic credentials/cookies, raw WBXML and no replay/fallback. Its
request body is capped at 64 MiB; the final serialized request head and combined
response headers/trailers are capped at 64 KiB / 200 fields. Nonidentity content
encoding and oversized declared response lengths are rejected before body reads.

The native client uses a finite total request deadline including connection
setup; the former ex_ssl receive deadline started after connecting. `:infinity`
is rejected before dispatch; finite zero is supported. Native chunk lines are
bounded at 8 KiB (formerly 1 KiB), and native trailers additionally have a
128-field / 64 KiB cap. Native parsing accepts valid 100/103 interim responses
and rejects 101 protocol switches; the former custom EAS parser rejected all
informational responses. Fetch 0.21.10 rejects non-HTTP/1 major versions while
accepting HTTP/1 minor versions, following HTTP/1 compatibility semantics.

## Dependency and validation checkpoint

The 2026-10-22 refresh candidate declares exact Fetch and ex_ssl 0.21.16,
with matching HTTP/TLS/QUIC packages. DuskMoon tooling is 10.0.2, UI is 10.0.11
and Decimal is 3.2.0. The full umbrella passes **1,635 tests**, zero failures,
across 17 apps in one invocation, seed 42. Strict dev/test/prod compilation,
formatting, development/production assets and both fresh releases' actual
HTTP startup pass. npm frozen installation and verification cover 330 packages;
security audit reports zero vulnerabilities, with direct/all Hex and npm
workspace audits complete. Published 0.21.16 changes HPACK documentation without
changing HTTP/TLS client executable code or policy.

The packaged/runtime HTTP/TLS cohort is 0.21.16 in both releases; Gaoxy is
0.12.1. Web HTML, API health and signed Edge status return 200 with Mix
unavailable and Bandit/ThousandIsland absent. The local smoke report is
`tmp/gaoxy-release-smoke/run_1792682683_1ed5f51d/report.json`.
Target deployment and credentialed provider staging remain separate.

The preceding 0.21.15 / UI 10.0.10 checkpoint passed all 1,635 tests across
17 apps, strict dev/test/prod compilation, assets and fresh main/Edge packaged
startup. See the
[dependency maintenance record](../.agents/skills/develop/references/dependency-maintenance.md)
for version-specific results. The following results retain the original
migration checkpoint.

Originally, core declared exact Fetch 0.21.10 and connectors used matching ex_ssl 0.21.10; paired
HTTP/TLS/QUIC packages align. DuskMoon bundler/runtime/npm/QuickBEAM tooling moves
from 9.16.7 to 9.16.16 to resolve compatible Fetch constraints. Phoenix DuskMoon UI
remains 9.16.7; the frontend source is unchanged. The npm lock records the previously missing
transitive dependency closure required by the new frozen-install check; no
existing locked package version changes.

Historical 2026-10-14 baseline scoped tests passed 126 cases. Seven fresh Hex actual-wire probes passed
for raw bytes, secret-safe telemetry, upload/no replay, acknowledged streaming,
cancellation, completion and structured pre-send errors. The 2026-10-14 scoped regression on the isolated database passed seed 42: core 38,
connectors 655, outbound 179, cloud 13 and OAuth LiveView 13 (**898 total, zero
failures**). Core includes 22 client-specific actual-wire/test-seam gates, including
explicit ex_ssl trust/cancel, gzip/deflate bounds and caller-death cancellation.

Dev/test `mix compile --warnings-as-errors`, changed-file formatter validation,
`git diff --check` and local Markdown targets passed. `mix npm.ci`, `mix npm.verify`
(432 packages) and `mix assets.build` passed after completing the lock's transitive
records. No existing npm locked version changed; unrelated Decimal stays 3.1.1.
OAuth tests initially failed for missing generated asset manifests in the new
worktree, then passed after building assets. Credentialed provider staging,
production runtime switching, merge/push and publication were not performed.

An initial connector run failed because the existing `manifold_test` database
recorded migration `20261010000200` but lacked three columns present in its current
source. Validation uses a fresh `manifold_http_fetch_client_test` database, with
`TEST_DATABASE_URL` unset and `POSTGRES_TEST_DB` set; the existing database is
preserved. No schema or migration source changes are part of this task.

Reproduce the affected regression from the main project root:

```sh
devenv shell -- env -u TEST_DATABASE_URL POSTGRES_TEST_DB=manifold_http_fetch_client_test \
  bash -lc 'mix test apps/manifold_core/test apps/manifold_connectors/test apps/manifold_outbound/test apps/manifold_cloud/test apps/manifold_web/test/manifold_web/google_login_live_test.exs apps/manifold_web/test/manifold_web/microsoft_device_live_test.exs --seed 42'
```

At the historical 0.21.8 focused checkpoint on 2026-10-15, core 41 and DAV/EAS 102 tests passed
(seed 42). A subsequent independent version-admission review added the actual
TLS gate for #121; it failed because the native adapter returned status 200.
The full affected regression (seed 42, isolated DB) ran **907 tests**:
core 41, connectors 661, outbound 179, cloud 13 and OAuth LiveView 13.
**906 passed; one failed**, exactly the #121 EAS response-version rejection gate.
There were no other failures or exclusions. That checkpoint was BLOCKED, and
is superseded by the 0.21.10 verification below.

Dev/test strict compilation, changed-file format and diff checks passed.
The dependency cleanup initially left stale compiled application metadata asking
for Req; regenerating umbrella application files resolved that startup failure.
Req and Finch lock entries are pruned. No new frontend changes were made;
the prior npm/asset checks above remain the relevant tooling evidence.

Source inventory has no Req/Mint/Finch/httpc business transport calls or direct
Req/Mint dependencies in this migration worktree. Req/Finch lock entries are
removed; Mint remains a tooling dependency. Credentialed provider staging is
separate from controlled wire gates. Main and its prior TLS-audit edits are
preserved.

## Final 0.21.10 acceptance — 2026-10-15

**PASS:** the full affected regression ran **910 tests, zero failures and no
exclusions**, seed 42, against the isolated database: core 41, connectors 664,
outbound 179, cloud 13 and OAuth LiveView 13. This includes four real TLS
version-admission gates (OTP/ex_ssl × HTTP/0.9/HTTP/2.0), existing malformed EAS
framing tests, and DAV method/body/deadline/trailer gates. The former failing
#121 gate now rejects the response with `:invalid_status_line`.

Dev/test `mix compile --warnings-as-errors`, changed-file format checks,
`git diff --check` and local Markdown targets passed. Dependency resolution
upgraded only the eight paired HTTP/TLS/QUIC packages from 0.21.8 to 0.21.10;
DuskMoon tooling, UI and Decimal remain at their preceding locked versions.
The resolved EAS callsite TODO was removed. Application source inventory has
no direct Req/Mint/Finch/httpc client calls; all business HTTP requests use the
shared native client. IMAP/SMTP sockets, server/database TLS and dependency
tooling remain outside this migration's HTTP-client scope.

All planned business client paths are implemented and locally verified for
the v0.6.4 release candidate. The user authorized integration into `main` and
publication through the existing release workflow. Credentialed provider staging
and a running-service switch remain **NOT RUN**; publication evidence is the
[v0.6.4 GitHub release](https://github.com/gsmlg-opt/manifold/releases/tag/v0.6.4).
OTP remains the default TLS backend. The historical 0.21.8 failed checkpoint
above is superseded by this run.

## v0.6.4 release preparation — 2026-10-15

The user authorized merging the migration into `main` and releasing the next
patch version, v0.6.4. Pre-release full-umbrella validation passed **1,469 tests,
zero failures**, seed 42, across all 17 apps using the isolated test database.
Repository-wide formatting passed. JavaScript checks passed with zero errors
and two existing unused catch-variable warnings in `app.js`.

Prior main-branch TLS audit additions are retained as explicitly historical
records in [TLS_BACKENDS.md](TLS_BACKENDS.md) and its develop reference. The
obsolete MintAdapter's only extra line was the #113 TODO; #113 is now CLOSED,
and no deleted transport is restored. The exact pre-merge dirty files are also
preserved in a named Git stash. The default TLS backend remains OTP.

Production preparation also passed: strict prod compile, production assets,
assembly of both `manifold` and `manifold_edge`, verification of their paired
0.21.10 HTTP/TLS/QUIC application closures and absence of the test-only HTTP
injection module. Each assembled release passed an actual local HTTP request
through `Manifold.Core.HTTPClient` using `release eval`, without starting the
business/database applications. These checks validate the release candidate;
GitHub artifacts and Docker publication are verified separately by the release
workflow. No running development service or provider account was restarted.
