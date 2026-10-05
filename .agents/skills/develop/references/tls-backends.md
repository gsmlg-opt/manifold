# Explicit outbound TLS backends

- Contract and operator configuration: `docs/TLS_BACKENDS.md`.
- Selection and opaque dispatch: `Manifold.Connectors.TLS`; OTP default,
  `:tls_backends` account UUID map or explicit connection `:tls` settings.
- Direct TLS/STARTTLS: `IMAP.Client` and `SMTP.Client`; reject parser-buffer
  plaintext before upgrade. Never retry or fall back after TLS failure.
- SMTP account routing: `Manifold.Outbound.Provider.SMTP.connection_settings/1`
  carries the checked-out method's account UUID into the connector.
- EAS: `EAS.Client` and `EAS.HTTPAdapter`, using Req's adapter module boundary.
  HTTP/1.1 only, fresh verified connection, no pooling, redirects or retries.
- The ex_ssl dependency is pinned independently; update it only after its own
  protocol/public-API/OTP/OpenSSL gate passes. Do not change inbound SMTP, web,
  database or unrelated Req TLS while working on these backends.
- Regression tests live under connector tests; local TLS fixtures are generated
  by `test/support/tls_peer.exs`. Production accounts/endpoints are not fixtures.
- Validation status and deliberate exclusions belong in the compatibility
  matrix; do not claim universal OTP parity or security certification.
