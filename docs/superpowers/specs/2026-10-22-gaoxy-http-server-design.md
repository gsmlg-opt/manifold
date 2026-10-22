# Gaoxy HTTP server migration

Approved scope: replace Bandit in both Phoenix Endpoints and the separately
supervised Edge Plug listener, removing the three direct Bandit dependencies.

Implementation status: implementation, scoped acceptance and local packaged
startup **PASS** with published Gaoxy 0.9.0. The release fixes
[large LiveView message rejection](https://github.com/gsmlg-dev/gaoxy/issues/9)
and [premature active Edge shutdown](https://github.com/gsmlg-dev/gaoxy/issues/10).
The isolated candidate has 257 passing scoped tests and both production
releases serve actual local HTTP traffic. No merge or deployment has occurred. The
[maintenance record](../../../.agents/skills/develop/references/http-server-migration.md)
contains current evidence and the resolved historical failures.

## Integration

Use published `gaoxy_http ~> 0.9.0` and the official
`{:websock_adapter, "~> 0.9.0", hex: :gaoxy_websock_adapter, override: true}`
distribution under its existing OTP application name. Web and API retain
Endpoint-owned supervision with `Gaoxy.PhoenixAdapter`. Edge supervises
`{Gaoxy.HTTP, id: :edge_api, plug: {Manifold.Edge.Router, []}, ip: ..., port: ...}`.

Keep current IPv4/IPv6 binding, runtime port and server-enable settings, public
HTTPS URLs and Caddy TLS termination. Preserve sessions, CSRF/Origin policy,
WebSocket and longpoll socket routes, code reload, parsers and application
authorization. No native TLS, HTTP/2, HTTP/3, provider transport, database schema
or asset changes are required.

## Acceptance

Run the current Web/API/Edge suites as a baseline in isolated test databases.
Add real loopback listener tests for Phoenix startup/server_info, static/HEAD,
API JSON POST, LiveView WebSocket join/event and longpoll, webhook raw-byte
signatures/413, attachment chunking and disconnect cleanup. Edge tests must
exercise its application-owned listener, signed method/path/Host/raw-body,
replay and duplicate-header rejection, body limits and raw-file delivery.
Include a 300 KiB composer body with HTML expansion and a 5 MiB ASCII body,
persisted bytes and a reconnect; include an admitted Edge request progressing
throughout supervised shutdown, with the instance's actual termination reason.

Inspect the published finite request deadlines and service/WebSocket budgets
against actual consumer requests; preserve application limits rather than
adding speculative tuning. Web uses a 64 MiB service byte budget to preserve
the existing 10,000,000-byte WebSockAdapter frame capacity: Gaoxy clamps both
frame and message ceilings to one quarter of this budget. API uses 16 MiB
because Plug can retain both chunks and a flattened body at its existing
8,000,000-byte parser limit. Edge derives its service budget as
`max(4 MiB, 4 * max_request_bytes)`
and its native body ceiling as `max(8 MiB, max_request_bytes + 1)`, preserving
the production default of 2,097,152 bytes and larger configured limits. These
are service-wide admission budgets, not application body limits or a bound on
total BEAM memory. HTTP retains a 30-second total deadline and 5-second
header/read/write limits, including chunked attachment transfers. WebSocket
retains 60-second idle and 24-hour lifetime limits. A dependency defect is routed
upstream according to AGENTS.md; a blocker stops its affected path without a
local workaround.

Update deployment guidance and the develop maintenance record with actual
results. Format changed Elixir files, strictly compile, and run only these
three applications' tests. Assemble both releases and verify their dependency
closures and actual local HTTP startup using isolated databases. Production
deployment and publication are outside this implementation request.
