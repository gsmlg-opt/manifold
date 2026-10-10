# Default HTTP client migration audit

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
