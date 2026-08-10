# Edge-only SMTP Runtime

## Feature

- **Date**: 2026-08-10
- **Status**: done
- **Scope**: main and edge OTP release/runtime composition

## Ownership and behavior

- `manifold` is the mail-client runtime and does not include or enable inbound SMTP.
- `manifold_edge` includes `manifold_smtp` permanently and enables its listener through edge runtime configuration.
- `manifold_smtp` remains in the umbrella for edge compilation and focused tests; its default supervisor is inert.
- `Manifold.Connectors.SMTP.Client` is outbound client functionality and is independent of the inbound listener.

## Configuration impact

- Shared configuration sets `config :manifold_smtp, enabled: false`.
- Edge runtime configuration sets `enabled: true` with `Manifold.Edge.SMTP` as resolver and ingest adapter.
- There is no main-runtime SMTP enable environment variable.

## Validation

- `mix test apps/manifold_data/test/manifold/config_test.exs`
- `mix test apps/manifold_smtp/test`
- `mix test apps/manifold_connectors/test/manifold/connectors/smtp_send_method_test.exs`
- `mix format --check-formatted`
- Restart normal devenv runtime and verify ports `4290` and `4292` respond while `2525` is closed.

## Follow-ups

- Keep future inbound SMTP changes scoped to `manifold_edge` unless the product runtime boundary is explicitly revised.
