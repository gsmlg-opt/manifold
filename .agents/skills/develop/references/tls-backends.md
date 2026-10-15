# Explicit outbound TLS backends

- Contract and operator configuration: `docs/TLS_BACKENDS.md`.
- Selection and opaque dispatch: `Manifold.Connectors.TLS`; OTP default,
  `:tls_backends` account UUID map or explicit connection `:tls` settings.
- Direct TLS/STARTTLS: `IMAP.Client` and `SMTP.Client`; reject parser-buffer
  plaintext before upgrade. Never retry or fall back after TLS failure.
- SMTP account routing: `Manifold.Outbound.Provider.SMTP.connection_settings/1`
  carries the checked-out method's account UUID into the connector.
- EAS: `EAS.Client` and the `EAS.HTTPAdapter` policy boundary call the shared
  `Manifold.Core.HTTPClient` and native `HTTP.fetch` with explicit TLS selection.
  HTTP/1.1 only, fresh verified connection, no pooling, redirects or retries.
- DAV: `DAV.Transport` also calls the shared native client, preserving extension
  methods, raw XML and trailer metadata. The former Mint adapter is removed.
- Current HTTP dependencies are locked Hex `http_fetch == 0.21.10` and
  `ex_ssl == 0.21.10`. EAS timeouts are finite non-negative milliseconds (`0`
  supported, `:infinity` rejected); its total request deadline includes connect.
  Native Fetch owns framing: chunk-size lines are bounded at 8 KiB, trailers at
  64 KiB/128 fields. EAS additionally caps combined response headers/trailers
  at 64 KiB/200 fields, and bodies at 64 MiB. No private HTTP parser remains.
- The ex_ssl dependency is pinned independently; update it only after its own
  protocol/public-API/OTP/OpenSSL gate passes. Do not change inbound SMTP, web,
  database or unrelated HTTP TLS while working on these backends.
- On 2026-10-09 dependency maintenance replaced the unavailable Git revision
  with exact Hex `ex_ssl == 0.17.1`, matching DuskMoon's new Fetch dependency
  graph. The published-source protocol/public-API/OTP/OpenSSL gate passed 430
  executed tests/properties with no exclusions or skips; Manifold's mandatory
  TLS workflow scope passed 46 tests. OTP remains the default backend.
- On 2026-10-15 the 0.21.8 focused native migration gate passed 41 shared HTTP-client
  tests and 102 DAV/EAS tests, seed 42, zero failures. This local consumer gate
  does not replace the dated standalone library audit or provider staging.
- Regression tests live under connector tests; local TLS fixtures are generated
  by `test/support/tls_peer.exs`. Production accounts/endpoints are not fixtures.
- Validation status and deliberate exclusions belong in the compatibility
  matrix; do not claim universal OTP parity or security certification.

## Native EAS migration checkpoint — 2026-10-15

Published 0.21.10 includes
[PR #124](https://github.com/gsmlg-dev/http_fetch/pull/124), closing
[http_fetch#121](https://github.com/gsmlg-dev/http_fetch/issues/121). The native
HTTP/1 parser now rejects a textual HTTP/2.0 status line. The native migration
is accepted for the v0.6.4 release candidate: the full affected regression passed 910 tests,
zero failures or exclusions, seed 42 (41 core, 664 connectors, 179 outbound,
13 cloud, 13 OAuth). It includes four actual-TLS rejection gates for
OTP/ex_ssl × HTTP/0.9/HTTP/2.0. Strict development and test compilation also
passed. No local parser workaround is used. OTP is still the default TLS
backend. Publication and credentialed provider staging remain outside this
local acceptance evidence.

Historical 0.21.8 full affected regression: 907 tests, 906 passed and only the
#121 gate failed. Preserve that dated result separately from the 0.21.10 rerun.

## 2026-10-14 replacement audit (historical)

- The then-installed Hex `ex_ssl 0.17.1` passed 39 connector TLS/mail/EAS tests
  and 7 outbound SMTP provider tests in Devenv (Elixir 1.18.5 / OTP 28).
- The then-latest Hex `ex_ssl 0.21.7` passed the same 39 connector tests in a
  separate consumer project using Manifold's compiled application modules and
  matching Req/Mint versions. Protocol consolidation was disabled so dynamically
  loaded Manifold Inspect implementations remained available. This was a
  bounded compatibility check, not validation of an upgraded umbrella graph.
- Public TLS 1.3 with mandatory system-CA/hostname verification passed for
  iCloud IMAP/SMTP and Microsoft Graph using unauthenticated protocol exchanges.
  Google TLS 1.2/1.3 timed out with both ex_ssl and OTP and remained unverified.
  No credentialed provider acceptance or delivery was tested.
- The audit identified
  [gsmlg-dev/http_fetch#113](https://github.com/gsmlg-dev/http_fetch/issues/113),
  now closed. ex_ssl rejected the captured three-certificate CalDAV chain;
  its two-certificate prefix verified with the same system trust. Fixed-IP live
  attempts failed twice with ex_ssl and succeeded twice with OTP. The issue
  contains the public certificate fixture and deterministic reproduction.
- Its advice to retain DAV's Mint/OTP transport and its Req/Mint inventory are
  superseded by the verified native Fetch migration above, which keeps OTP TLS
  as the default. The audit changed no dependency or production configuration.
  Server/database TLS remain outside the selective IMAP/SMTP/EAS backend
  boundary. Neither the audit nor the local migration gate proves credentialed
  public CalDAV acceptance with ex_ssl or universal OTP replacement.
