# HTTP client migration

## Current implementation — 2026-10-22

Status: Gmail/Graph connector/OAuth, Gmail/Graph/Resend outbound, Cloud and DAV
and EAS use native Fetch. The original v0.6.4 migration was developed in
`codex/http-fetch-client` on the release fixing
[http_fetch#121](https://github.com/gsmlg-dev/http_fetch/issues/121).

- Core owns `Manifold.Core.HTTPClient`, Response/TransportError normalization,
  request encoding, bounded raw/content decoding, lazy streams, cancellation
  and a process-owned test-only injection seam.
- Provider authentication, admission, Retry-After, no replay/redirect and
  uncertain-submission policy remain in their owning apps. Graph counts every
  raw byte while retaining at most 64 KiB; only raw-empty 202 is accepted.
- Raw imports bypass the generic 64 MiB cap; Sync/spool retain import limits.
  Cloud cancels rejected bodies and returns lazy raw response Enumerables.
- DAV owns authority checks; its transport preserves method tokens/XML bytes,
  trailing ETags, 8 MiB body / combined 64 KiB and 1,000-field header limits,
  and a finite total deadline. The obsolete MintAdapter is removed.
- EAS keeps protocol policy/preflight in HTTPAdapter and uses the common client.
  Its finite total deadline includes connect, rejects infinity, supports zero;
  native chunk lines cap at 8 KiB and trailers at 128 fields / 64 KiB. Combined
  EAS initial/trailer limits remain 200 fields / 64 KiB; raw WBXML, verified TLS,
  no replay/fallback and request/body limits remain explicit.
- Fetch/ex_ssl and paired HTTP/TLS/QUIC packages use exact 0.21.15. DuskMoon
  tooling is 10.0.2, UI 10.0.10 and Decimal 3.2.0. The current dependency
  maintenance passed all 1,635 tests across 17 apps, strict dev/test/prod compile,
  assets and fresh packaged startup. See [dependency maintenance](dependency-maintenance.md)
  for the current results and explicit npm installer exception.
- OTP TLS remains default. No global ex_ssl switch is authorized by this task.
- Legacy `:req_options` containers remain; application sources/dependencies
  no longer use Req/Mint transports. Mint remains transitively for tooling.

Upstream #114/#115/#121 are closed. Published 0.21.10 includes the #121
response-version rejection fix (PR #124) and activation-cancellation fix
(PR #125). EAS wire regression coverage includes both OTP/ex_ssl backends and
HTTP/0.9/HTTP/2.0 text status lines. Remove the resolved callsite TODO; there is
no local response-parser workaround. See
[HTTP_CLIENT.md](../../../../docs/HTTP_CLIENT.md) for full contracts,
compatibility changes and current verification results.

Historical 2026-10-14 checkpoint: 898 affected tests passed, seed 42, on an
isolated database; dev/test compile, format, npm install/verify and asset build
passed. At that date DAV/EAS were blocked by #114/#115 on 0.21.7. Preserve that
history in the implementation plan. The 2026-10-15 focused checkpoint passed
core 41 plus DAV/EAS 102 before the new #121 gate was added. Credentialed provider
staging, merge/publication and runtime switching remain NOT RUN.

Historical 0.21.8 affected regression: 907 tests, 906 passed, one #121 gate failed,
no exclusions. Dev/test strict compile, changed-file format, diff/Markdown
checks passed. That checkpoint was blocked and is superseded by 0.21.10 verification.

## Historical default-client audit

- Date: 2026-10-09.
- Status: investigation complete; installed Fetch 0.17.1 still fails the
  reproduced secret-safe telemetry requirement. Upstream
  [gsmlg-dev/http_fetch#31](https://github.com/gsmlg-dev/http_fetch/issues/31)
  is closed as of 2026-10-10; a compatible consumer dependency update,
  independent verification and migration design approval remain pending.
- Scope: application HTTP clients in connectors, outbound and cloud. This audit
  does not change their default client or TLS selection.

## Published dependency and API

The live Hex release inspected is `http_fetch 0.17.1`, including the actual Hex
source archive. Its `http_core` and `http_runtime` dependencies require matching
`0.17.1` packages, including `ex_ssl`, `elixir_quic` and `elixir_quic_http3`.
DuskMoon 9.16.7 now includes Fetch through its npm/QuickBEAM tooling; application
code must declare its own dependency when it starts using Fetch. OTP SSL and
HTTP/1 remain Fetch's defaults. No published Req adapter was found.

`HTTP.fetch/2` returns a promise; awaiting it yields an HTTP response or error.
Native migration requires explicit form/JSON/query/auth encoding, normalized
status/headers/body/errors, and stream handling. Unknown Req options cannot be
passed through unchanged. Redirect following defaults to enabled; protected
provider/edge paths require manual redirects. Finite promise waits can exit on
timeout; the adapter must settle and clean up network/stream resources.

## Owning call paths

This inventory records the 2026-10-09 audit before iCloud integration. Any
project-wide migration must also audit DAV's Apple URL allowlist, Basic credential
secrecy, read-only methods, response limits and redirect refusal.

| App | Module / entry point | Contract to preserve |
| --- | --- | --- |
| manifold_connectors | Provider.Gmail, private request/5 | OAuth form, bearer auth, JSON; retry/redirect disabled; Gmail admission/cooldown |
| manifold_connectors | Provider.MicrosoftGraph, private request/4 | Provider-specific OAuth/device/token flows, JSON/raw MIME, immutable IDs, Graph limiter/Retry-After |
| manifold_connectors | EAS.Client and EAS.HTTPAdapter | OPTIONS/POST, Basic auth, cookies, binary WBXML, 15/60-second deadlines; explicit ex_ssl adapter |
| manifold_outbound | Provider.Gmail | Base64url MIME JSON; no replay/redirect; uncertain submission |
| manifold_outbound | Provider.MicrosoftGraph, production transport | Direct Mint; transmission phase, secret-safe diagnostics, bounded response, empty-body 202 acceptance |
| manifold_outbound | Provider.Resend | JSON, idempotency key, Retry-After and error classification |
| manifold_cloud | Client, private request and stream_raw | Exact signed method/path/body, no redirect, buffered and Enumerable streaming delivery |

IMAP/SMTP socket clients, inbound/server TLS, and dependency downloaders are
outside the application HTTP-client migration.

## Suggested design for approval

The proposed target is a small `Manifold.Core.HTTPClient` backed by native Fetch,
with explicit request/response/error and streaming contracts. Preserve provider
retry/admission and authentication policy in their owning apps. Convert existing
Req-specific response matching and mocks along with each call path.

An alternative Req adapter retains the Req API, codecs, `%Req.Response{}` and
Req.Test while replacing its transport. It has less code churn but changes the
network transport, rather than replacing Req as the application client API.
Neither choice has been approved or implemented by this investigation.

Ordinary provider paths can be migrated first. EAS and Graph outbound require
separate acceptance before claiming the project-wide default is migrated:

- EAS explicitly rejects unsupported options, uses fresh verified HTTP/1.1
  connections, and prevents redirects and mutation replay on its ex_ssl path.
- Graph outbound avoids credential-bearing transport telemetry, limits retained
  error bodies to 64 KiB, requires an empty raw body with status 202, and
  distinguishes definite pre-transmission errors from uncertain submissions.
- Cloud streaming promises an Enumerable. Fetch may return a stream PID;
  `Response.read_all` buffers the full body and can raise on stream failure, so
  it cannot substitute for the streaming contract.
- Preserve raw-response semantics where provider acceptance depends on exact
  bytes; review upstream raw-response issue #27 before that phase.

## Blocker and evidence

The actual Hex 0.17.1 `lib/http.ex` calls `HTTP.Telemetry.request_start` before
spawning the network task. `lib/http/telemetry.ex` includes the full URI and
headers in request-start metadata with no supported redaction/disable control
found. A local executable reproduction attached a telemetry listener and read
fake Authorization, Cookie and x-manifold-signature values unchanged. It exited
0 with `TELEMETRY_SECRET_DISCLOSURE_REPRODUCED http_fetch=0.17.1`.

Issue #31 was filed as a Bug labeled `internal request`, severity blocker, requesting
secret-safe defaults and an explicit disable control. A TODO at the existing
Gmail request callsite tracks it. The issue is closed upstream, but the installed
0.17.1 package has not been replaced or revalidated. Resume migration only after
a compatible dependency update and independent verification; do not intercept other telemetry handlers
or remove required wire credentials as a local workaround.

## Acceptance required after upstream fix and design approval

Keep scoped provider regression tests and add controlled real-network gates for
form/JSON/raw bytes, streaming cancellation/truncation, timeout cleanup, redirect
refusal, Retry-After, exactly one submission dispatch, Graph bounded responses
and empty-body 202, and absence of secrets in telemetry/logs/errors. Req.Test
alone cannot prove Fetch traffic: Req plug mocks bypass network adapters.
Credentialed Google/Microsoft/Resend staging is a separate verification step.
No schema, OAuth credential configuration, or production default changed here.

## Final native acceptance — 2026-10-15

**PASS:** Fetch/ex_ssl and all eight installed companion packages are 0.21.10.
All business clients (Gmail/Graph/OAuth, outbound Gmail/Graph/Resend, Cloud,
DAV and EAS) use the common native client. #121 is fixed and its TODO removed;
four actual TLS gates reject HTTP/0.9/HTTP/2.0 on OTP and ex_ssl. No private
response parser or Req/Mint application transport remains.

Affected regression: core 41, connectors 664, outbound 179, cloud 13 and OAuth
13 = **910 tests, zero failures/exclusions**, seed 42, isolated DB. Dev/test
strict compile, changed-file formatting, diff and local Markdown targets passed.
No new frontend source/lock changes were needed in this resumed checkpoint.
The prior 0.21.8 failure remains historical. The user authorized integration
into `main` and release v0.6.4 through the existing workflow. Publication evidence
is the [GitHub release](https://github.com/gsmlg-opt/manifold/releases/tag/v0.6.4);
credentialed staging and a running-service switch remain NOT RUN. OTP default
and finite request timeout policy remain unchanged by this dependency repair.

## v0.6.4 integration/release preparation

User-authorized merge and release preparation passed the full umbrella suite:
**1,469 tests, zero failures**, seed 42, 17 apps, isolated database. Global format
passed; JS checks had zero errors and two pre-existing unused catch warnings.
Prior main TLS audit records are combined into historical documentation; the
original dirty files remain in a named stash. Release workflow owns the patch
version bump and both application/Edge artifacts. See [HTTP_CLIENT.md](../../../../docs/HTTP_CLIENT.md)
for the current release checkpoint and [v0.6.4](https://github.com/gsmlg-opt/manifold/releases/tag/v0.6.4)
for publication evidence when the workflow completes.

Production preparation also passed: strict prod compile, production assets,
assembly of both `manifold` and `manifold_edge`, verification of their paired
0.21.10 HTTP/TLS/QUIC application closures and absence of the test-only HTTP
injection module. Each assembled release passed an actual local HTTP request
through `Manifold.Core.HTTPClient` using `release eval`, without starting the
business/database applications. These checks validate the release candidate;
GitHub artifacts and Docker publication are verified separately by the release
workflow. No running development service or provider account was restarted.
