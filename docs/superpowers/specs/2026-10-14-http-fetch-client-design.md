# Native Fetch business HTTP clients

User authorization: migrate all business HTTP clients to http_fetch. The existing
migration audit proposed a native shared client; this implementation uses that
boundary. A Req adapter would leave Req semantics and types throughout business
code; per-provider Fetch calls would duplicate transport safety and streaming.

## Boundary

`Manifold.Core.HTTPClient` owns native `HTTP.fetch/2`, encoding, normalized
responses, bounded reads, lazy response enumeration, cancellation and safe errors.
Provider modules own their existing authentication, admission, Retry-After,
retry/dispatch policy and protocol-specific error classification. No new GenServer
is needed for the client; Fetch owns its tasks/streams.

`request/1` and `post/1` return `{:ok, %HTTPClient.Response{}}` or
`{:error, %HTTPClient.TransportError{}}`. Response headers remain a map of value
lists; raw body size is recorded separately from any retained prefix. Unknown
request options fail before dispatch. Legacy `:req_options` configuration
containers remain readable while their implementation and injected test module
change; there is no Req dependency in migrated business transport.

All native requests use HTTP/1, manual redirects, no consumer automatic replay,
secret-safe telemetry controls, raw content decoding disabled at the transport,
and OTP TLS by default. JSON/form/query/auth encoding is explicit. EAS may retain
its explicit ex_ssl selection and verified ClientHello profile; no fallback occurs.

## Required behavior

- Gmail/Graph OAuth and sync preserve form/query/JSON/raw MIME and provider limits.
- Gmail/Resend submission preserve exactly one dispatch and existing uncertain
  outcomes, authorization boundaries and idempotency/Retry-After rules.
- Graph submission accepts only a truly raw-empty 202, retains no more than64KiB
  of response body, counts every raw byte and keeps bounded diagnostic headers.
  Only proven pre-transmission errors are retryable; unknown/send/read failures
  remain uncertain.
- EAS preserves binary WBXML, cookies, finite option policy, peer verification,
  request/response bounds, parsing failures and mutation replay restrictions.
- DAV must preserve Apple authority controls, Basic credential secrecy, method
  tokens, hard response limits and total deadline.
- Cloud signatures cover exactly the sent method/path/body. Raw delivery remains
  a lazy Enumerable; completion, errors and early consumer halt close Fetch streams.
- Test injection is owned per test process, supports explicit allowances for
  LiveView processes, and is separate from controlled real-wire Fetch tests.

## Dependency baseline

Current Hex Fetch0.21.10 resolves with matching HTTP/TLS/QUIC packages. DuskMoon
bundler/runtime/npm/QuickBEAM must move from9.16.7 to9.16.16 for their Fetch
constraints; Phoenix DuskMoon UI remains9.16.7. The npm lock needs its missing transitive dependency closure
recorded for the upgraded frozen-install check; existing locked versions and
user-facing UI source stay unchanged. Verify compilation and affected UI integration consumers.

## Historical blocked boundary — 2026-10-14

DAV cannot migrate with published0.21.7: its Request method allowlist rejects
PROPFIND and REPORT before network activity, even in proxy mode. Upstream
[http_fetch#114](https://github.com/gsmlg-dev/http_fetch/issues/114) is Feature,
internal request, severity blocker. Keep the existing DAV implementation, mark
its callsite, and do not claim all clients have migrated until a fixed release
passes the actual DAV tests. This is pending scope, not completed scope.

EAS also remains on its existing client/adapter: published Fetch 0.21.7 accepts
malformed chunk framing and extensions, conflicting Transfer-Encoding/Content-Length
and status 600. [http_fetch#115](https://github.com/gsmlg-dev/http_fetch/issues/115)
is a Bug, internal request, severity blocker. Preserve the existing EAS parsing
acceptance gates and resume only with a fixed, verified dependency release.

The ex_ssl iCloud certificate-path issue
[http_fetch#113](https://github.com/gsmlg-dev/http_fetch/issues/113) remains separate:
Fetch with default OTP TLS can migrate DAV after method support lands.

## Verification

Baseline scoped tests: core16, provider/DAV connectors59, outbound42, cloud9,
all passed seed42. Add shared-client actual-wire gates before implementation.
Run affected connector/outbound/cloud/core suites and OAuth LiveView tests,
format/strict compile, and scan application sources for remaining Req/Mint calls.
Record any additional upstream capability blocker and stop that path without a
local transport workaround. No publication, production credentials or defaults
outside these business HTTP consumers are part of this request.

## Historical 0.21.8 boundary — 2026-10-15

#114/#115 are closed and verified against published 0.21.8. DAV is migrated,
with no local method serializer; EAS has a native candidate and no private
response parser. The focused core41/DAV+EAS102 gates passed before independent
review added a failing actual TLS response-version gate. Native HTTP/1 accepts
`HTTP/2.0 200 OK`; prior EAS rejected it. New upstream
[http_fetch#121](https://github.com/gsmlg-dev/http_fetch/issues/121) blocks final EAS
acceptance. Preserve the regression and stop that path without a local workaround.

The candidate's finite total deadline includes connect and rejects infinity
(accepts zero); native chunk lines cap at 8 KiB, trailers at 128 fields / 64 KiB,
and valid interim 100/103 responses are handled natively. EAS keeps its combined
200-field / 64 KiB header cap and 64 MiB request/response limits. OTP remains
default. Current checks and practical limits are in [HTTP_CLIENT.md](../../HTTP_CLIENT.md).

## Fixed dependency boundary — 2026-10-15

Upstream #121 is closed and its parser fix ships in published 0.21.10 (PR #124),
alongside HTTP/1 activation-cancellation hardening (PR #125). All eight installed
HTTP/TLS/QUIC companion packages move to 0.21.10. EAS uses the shared native
client; its resolved TODO is removed, with no local response parser. Four
actual TLS regression gates cover OTP/ex_ssl and HTTP/0.9/HTTP/2.0 text versions.
Current affected-suite evidence is maintained in [HTTP_CLIENT.md](../../HTTP_CLIENT.md).
The earlier failed checkpoint above is historical. OTP remains default;
credentialed provider staging and runtime switching remain separate.
