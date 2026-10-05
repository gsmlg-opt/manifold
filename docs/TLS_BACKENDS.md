# Opt-in TLS client backends

Manifold defaults to OTP `:ssl`. The experimental ex_ssl backend is limited to
outbound IMAP, SMTP submission and the EAS HTTP/1.1 adapter. It is an OTP-compatible
client API for an implemented subset, not a universal SSL replacement.

## Revisions and acceptance contract

The consumer baseline is `c21ea5d4e41b367bf2fa0b94dea54552cfa60af6`. The ex_ssl
baseline was `04180a504c55c65d4f339d459e011e2e2307bc49`; the dependency pins the
authenticated client implementation at `75ad1da8832a24f0d7f730e54ec80717b7346664`.
Library and consumer changes are reviewed separately. No release or production
configuration change is required by this development change.

| Consumer | Audited contract | Backend boundary |
| --- | --- | --- |
| IMAP | Host and existing-socket connect; send, raw recv length 0 (30 seconds), close. Binary/passive/raw, verify_peer, system cacerts, DNS SNI and HTTPS hostname match function. | `IMAP.Client` resolves TLS configuration before connecting; direct TLS and STARTTLS retain a backend-tagged handle. |
| SMTP submission | Same TLS calls/options; connect 15 seconds, remaining monotonic reply deadline; EHLO/STARTTLS/220/re-EHLO, AUTH, envelope, DATA and QUIT. | `SMTP.Client` uses the same handle boundary. Checked-out submission account identity selects the backend. Definite versus uncertain DATA outcomes remain unchanged. |
| EAS | Req OPTIONS/POST, URL/query, Basic auth headers, cookies, binary WBXML and response headers/body; connect 15 seconds, receive 60 seconds; HTTP/1 only, compression disabled. | Locked Req 0.7.3 supports a request adapter. Finch 0.23.0 and Mint 1.9.3 still use OTP; ex_ssl selects `EAS.HTTPAdapter` explicitly. |
| Unchanged consumers | Inbound SMTP, Phoenix/server TLS, database TLS, cloud HTTP, Gmail/Microsoft Graph HTTP, Resend and other Req calls. | Existing implementation and configuration. |

## Enable a controlled account

Add a deliberate operator configuration entry for the existing account UUID:

```elixir
config :manifold_connectors, :tls_backends, %{
  "account-uuid" => [backend: :ex_ssl]
}
```

Only new IMAP, SMTP submission and EAS connections for that account select
ex_ssl. Account settings and passwords do not need a schema migration. A low-level
client call can explicitly supply the same setting in its settings map:

```elixir
settings = Map.put(settings, :tls, backend: :ex_ssl)
```

An explicit connection setting takes precedence over the account map. Unknown
backends/options are rejected. There is no automatic fallback to OTP after a
connection, protocol or certificate failure, and no automatic replay of writes.

To return to OTP, remove the account entry or set `[backend: :otp]`, and establish
new connections. Existing handles retain the backend chosen when they connected.
No global replacement of Erlang's `:ssl` module takes place.

## Trust, identity and profiles

Both mail clients preserve their existing mandatory peer verification and system
CA trust. For a controlled service, the configuration may override CA certificates
or the DNS reference identity without weakening verification:

```elixir
tls: [
  backend: :ex_ssl,
  options: [
    cacertfile: "/absolute/path/to/test-ca.pem",
    server_name_indication: ~c"mail.test.example"
  ]
]
```

`cacertfile` replaces the default `cacerts` list. Other allowed TLS overrides are
`cacerts`, `customize_hostname_check`, `versions` and `ex_ssl: [profile: profile]`.
Profiles must be supported `SSL.ClientHello.WireProfile` values or `:default`.
They never change trust or reference identity. An IP connection to a DNS-named
service must keep its intended DNS identity in SNI. EAS profiles may omit ALPN or
offer only `http/1.1`; `h2` is rejected.

The library supports TLS 1.3 only, binary passive raw sockets, mandatory peer
verification, RSA-PSS RSAE and ECDSA P-256 server authentication, X25519/P-256,
and the TLS 1.3 AES-GCM/ChaCha20-Poly1305 suites available in OTP crypto.
It rejects unsupported options rather than accepting them silently.

## STARTTLS and resource handling

The caller must fully consume and validate the positive STARTTLS response.
Both mail clients reject unexpected bytes in their parser buffer before upgrade;
the shared boundary checks delivered and queued raw TCP bytes for both backends,
and ex_ssl repeats these checks before its ownership handoff. A failed upgrade
closes the owned socket and cannot resume plaintext. Connections and handshake
keys are never restarted or replayed.

The shared TLS boundary splits large ex_ssl application writes into bounded
1 MiB calls. Each library call emits valid TLS records and is attempted once.
Application protocols retain responsibility for their own message size limits.
The library independently bounds record, handshake, certificate, plaintext and
queued-write buffers and uses internal active-once TCP delivery.

## EAS HTTP scope

The explicit adapter uses a fresh verified connection for each request. There is
no pool, HTTP/2 negotiation, redirect following, transport retry or TLS downgrade.
This costs an authenticated handshake per request but avoids cross-account or
cross-trust connection reuse. Read-only EAS requests may negotiate protocol/query
formats after HTTP 400. The ex_ssl path does not replay Sync changes, Provision
or Settings requests; configure a supported protocol/query format before these
operations. Unsuccessful OPTIONS responses fail connection authentication.

The adapter accepts only its documented finite request-option subset; unsupported
Req/Finch transport, streaming, proxy, compression and custom adapter options fail
explicitly. It supports content-length, chunked and authenticated connection-close
responses. Abrupt TLS transport loss is an error, never the successful end of a
close-delimited response. Request and response data do not enter transport errors.

Supported request options are `method` (`:options` or `:post`), HTTPS `url`,
`headers`, binary/iodata `body`, `receive_timeout`, `user_agent`,
`connect_options: [timeout: ..., protocols: [:http1]]`, `compressed: false`,
and `decode_body: false`. EAS keeps WBXML bytes intact for its own decoder.
Timeouts accept non-negative milliseconds or `:infinity`; one monotonic receive
deadline covers all response fragments. The default connection/receive timeouts
are 15/60 seconds. Unknown or conflicting options fail before connecting.

Request and response bodies are limited to 64 MiB; each HTTP head/trailer section
is limited to 64 KiB and 200 fields, and each chunk-size line to 1 KiB. Streaming,
informational responses, HTTP upgrades, compressed responses and arbitrary HTTP
methods are outside this adapter's scope. Every request closes its connection.
Chunk sizes and extensions are validated against the bounded
[HTTP/1.1 grammar](https://www.rfc-editor.org/rfc/rfc9112.html#section-7.1);
unrecognized valid extensions are ignored and trailers remain separate headers.

## Compatibility evidence

| Layer | Evidence / readiness |
| --- | --- |
| Pure protocol/crypto/PKIX/profile components | ex_ssl deterministic vectors, framing properties, negative authentication tests and golden wire checks. |
| Public SSL API | Direct TLS, STARTTLS, repeated/large traffic, exact/available-byte receive semantics, deadlines/cancellation, owner death, application shutdown and cleanup regressions. |
| Independent interoperability | ex_ssl gate: 282 tests and 15 properties passed on OTP 28 and OTP 29 with integration enabled. Dedicated CI executes 44 OTP/OpenSSL/reference/lifecycle tests; live Caddy fingerprint CI passes through public SSL. |
| IMAP workflow | Controlled local OTP and ex_ssl peers pass LOGIN, SELECT, literal FETCH and LOGOUT over direct TLS and STARTTLS, plus failed authentication/certificate/transport and plaintext-boundary cleanup. |
| SMTP submission workflow | Controlled local OTP and ex_ssl peers pass EHLO, AUTH, envelope, DATA and QUIT over direct TLS and STARTTLS; existing submission outcome/account-routing regressions pass. |
| EAS HTTP/WBXML workflow | Real TLS OPTIONS/FolderSync exchanges preserve auth, cookies and binary WBXML. ClientHello is observed through EAS.Client; large/fragmented/framed responses, deadlines, redirect refusal, mutation replay prevention and redacted failures pass. |

Deliberate exclusions include TLS 1.2, server TLS, DTLS, QUIC, HTTP/2, active TLS
application modes, non-raw packet modes, client certificate authentication,
resumption and 0-RTT. Passing these tests is not security certification or evidence
of compatibility with every external mail provider.

## Validation commands

The library gate used these commands in the ex_ssl implementation checkout on
both OTP 28.5.0.5 / Elixir 1.18.5 and OTP 29.0.6 / Elixir 1.20.4:

```sh
mix format --check-formatted
mix compile --warnings-as-errors
MIX_ENV=test mix compile --warnings-as-errors
mix test --include integration
mix test --include integration test/ssl/connection_lifecycle_test.exs test/ssl/otp_reference_test.exs test/ssl/connection_interop_test.exs
```

Results: 282 tests and 15 properties passed in the full suite; 44 tests passed
in the dedicated suite. No interoperability tests were skipped. Local production
compilation (`MIX_ENV=prod mix compile --warnings-as-errors`) also passed.
OTP 29 used Docker image
`hexpm/elixir:1.20.4-erlang-29.0.6-ubuntu-noble-20260905`, a read-only source
mount, `MIX_BUILD_PATH=/tmp/ex_ssl_build`, and installed OpenSSL, CA certificates
and `libsctp1`. Its `e2e` directory passed formatting and strict compilation.

The [live Caddy fingerprint test](https://github.com/gsmlg-dev/ex_ssl/actions/runs/34843914989)
passed in CI through the public API (one test), and the
[dedicated OTP/OpenSSL job](https://github.com/gsmlg-dev/ex_ssl/actions/runs/34843914948)
passed all 44 tests on the pinned library revision. Live Caddy was not run
locally, following the library's existing e2e policy.

Manifold validation uses its configured Devenv Elixir 1.18.4 / OTP 28.5.0.3,
with a separate PostgreSQL 16 instance on port 55439 and a private socket
directory. The recorded full affected-scope command is:

```sh
devenv shell -- bash -c 'set -e; task_pg_root=$(cat /tmp/manifold-exssl-pg-root); export POSTGRES_SOCKET_DIR="$task_pg_root" TEST_DATABASE_URL="postgres://manifold_dev@localhost:55439/manifold_test?socket_dir=$task_pg_root"; mix format --check-formatted; mix compile --warnings-as-errors; MIX_ENV=test mix compile --warnings-as-errors; mix test apps/manifold_connectors/test apps/manifold_outbound/test/manifold/outbound/provider/smtp_test.exs'
```

Formatting and strict development/test compilation passed. The affected suite
passed **462 connector tests and 7 SMTP submission provider tests**, with no
skipped tests. The focused EAS adapter/safety/existing protocol run passed
**31 tests**. The new dedicated consumer CI job selects 46 boundary/mail/EAS/
submission tests and has no optional integration tag or skip path.

At consumer revision `91a9d8d`, the
[mandatory TLS workflow job](https://github.com/gsmlg-opt/manifold/actions/runs/34843650692)
and [full umbrella ExUnit job](https://github.com/gsmlg-opt/manifold/actions/runs/34843650595)
also passed in CI, together with formatting, strict compilation, JavaScript
checks and the configured frontend asset build. The final library-pin update
was revalidated locally with the same 469 affected tests before pushing.

An initial test attempt used the host toolchain/default database and failed
before running tests; it was rerun successfully in Devenv with the isolated
database. No production accounts, recipients, credentials or endpoints were
used. External-provider validation and a security audit remain outside this
controlled-test recommendation.
