# Native Fetch client implementation plan

> **For agentic workers:** Use subagent-driven-development or executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** Route every supported Manifold business HTTP request through native Fetch while preserving provider semantics and recording blocked paths honestly.

**Architecture:** A small shared core client normalizes Fetch responses/errors and streaming. Independent consumers use it; provider policies remain local. DAV is migrated after upstream method support; EAS response-version admission uses the published upstream fix.

**Tech Stack:** Elixir1.18.5, OTP28, Hex http_fetch0.21.10, existing ExUnit/Plug test injection and real TCP/TLS fixtures.

## Tasks and ownership

- [x] Baseline: run core/provider/DAV/outbound/cloud scoped tests, seed42;126passed.
- [x] Verify fresh published Fetch telemetry/raw/stream/error contracts:7actual-wire probes passed.
- [x] Create `.trees/http-fetch-client`, branch `codex/http-fetch-client`; preserve main's existing dirty files.
- [x] Update core dependency and paired ex_ssl; resolve compatible DuskMoon tooling.
- [x] Core owner: create `apps/manifold_core/lib/manifold/core/http_client.ex`, Response/TransportError/stream modules and test-only Test seam. Write failing wire tests, implement request/post, bounded raw reads, JSON/form/query/auth, phase errors, deadline cancellation and lazy Enumerable. Verify `mix test apps/manifold_core/test`.
- [x] Connector owner: migrate provider Gmail/Graph calls/types/tests to HTTPClient; retain admission, token scopes, immutable IDs, cooldowns and raw MIME. Update OAuth LiveView allowances to the new test seam. Verify provider and OAuth tests.
- [x] Outbound owner: replace Gmail/Resend Req and Graph Mint with HTTPClient. Preserve retained-body/full-byte semantics, empty202 and transmission phase classification. Verify all outbound tests and existing Graph real-TLS gates.
- [x] EAS final gate: native Client/HTTPAdapter replaces the private parser; published 0.21.10 fixes #121. Four actual TLS rejection gates and the full 910-test affected regression pass.
- [x] Cloud owner: migrate signed requests and stream_raw to HTTPClient, preserving exact signature bytes and lazy enumeration. Add real streaming/error/early-halt gates, verify cloud tests.
- [x] Dependency owner: remove direct Req/Mint dependencies from candidate apps and prune Req/Finch locks. Mint remains transitively for tooling.
- [x] Docs owner: update develop `http-client-migration.md`, architecture/README affected client references and resumable evidence; inspect final diff.
- [x] Final gate: affected core/connectors/outbound/cloud suites and OAuth tests pass, application-callsite inventory contains no unreported Req/Mint transport, independently inspect each changed app.
- [x] DAV: verified #114 fixes with 0.21.8 native method/XML/deadline/trailer gates; migrate Transport and remove MintAdapter.

## Native call example

```elixir
alias Manifold.Core.HTTPClient
HTTPClient.request(method: :post, url: endpoint, auth: {:bearer, token},
  json: payload, redirect: false, retry: false, receive_timeout: 15_000)
```

Graph's raw acceptance uses `decode_body: false, retain_body_bytes: 65_536` and
`response.private.raw_body_size == 0`. Cloud requests use `stream_response: true`
with `max_body_bytes: :infinity`; downstream ingestion enforces spool constraints.

Do not commit unrelated main edits or publish/merge a partial migration. Mark
upstream-blocked paths and keep runnable progress in this worktree.

## Historical verification checkpoint — 2026-10-14

- 2026-10-14: fresh isolated test DB, seed 42: core 38, connectors 655,
  outbound 179 and cloud 13 passed (885 total, zero failures).
- Core includes 22 client-specific tests with actual TCP/TLS traffic for
  encoding, raw bytes, bounded decompression, cancellation, caller death,
  deadlines, no replay and explicit ex_ssl trust/peer-close behavior.
- OAuth tests initially failed for missing generated asset manifests in the new
  worktree. After asset setup, all 13 passed: final total 898, zero failures.
- Dev/test strict compile, changed-file format, diff whitespace, local Markdown
  targets, frozen npm install/verify (432 packages) and assets build passed.
- npm lock adds missing transitive dependency records needed by the upgraded
  toolchain; existing locked versions are unchanged. Decimal remains 3.1.1.
- Existing `manifold_test` has a stale already-recorded iCloud migration shape;
  validation created `manifold_http_fetch_client_test` without changing it.
- DAV #114 and EAS #115 were verified OPEN after scoped regression. Those paths
  remain blocked and the all-client migration checkbox cannot be completed.

## Historical 0.21.8 verification checkpoint — 2026-10-15

- #114/#115 independently verified CLOSED; published paired HTTP/TLS/QUIC
  packages upgraded to 0.21.8; dependency resolution/compile passed.
- Focused core41 + DAV/EAS102 tests passed, seed42, including total deadlines
  with actual peer closure and combined initial/trailer limits.
- Independent review added the actual TLS HTTP/2.0 textual response gate;
  it fails because EAS native adapter returns successful200. Parser probe also
  accepts HTTP/0.9. Filed #121, Bug/internal request/severity blocker, with
  reproduction; no local workaround. EAS acceptance remains incomplete.
- Full affected regression: core41, connectors661, outbound179, cloud13,
  OAuth13 =907 tests;906passed, one #121 rejection gate failed, no exclusions.
  Dev/test strict compile, changed-file format and diff/Markdown checks passed.
  Final acceptance remains BLOCKED; see [HTTP_CLIENT.md](../../HTTP_CLIENT.md).
- Worktree remains uncommitted/unmerged. Main's prior edits and existing DB are
  preserved; no runtime backend switch, credentialed staging or publication.

## Final 0.21.10 checkpoint — 2026-10-15

- Verified #121 CLOSED and published paired 0.21.10 packages non-retired.
  Release contains PR #124 response-version admission and PR #125 HTTP/1
  activation-cancellation fixes. Updated all eight installed packages together.
- Former actual TLS red gate now passes. Four separately named OTP/ex_ssl ×
  HTTP/0.9/HTTP/2.0 rejection gates preserve exact errors and connection cleanup.
- Full affected regression: core 41, connectors 664, outbound 179, cloud 13,
  OAuth 13 = **910 tests, zero failures/exclusions**, seed 42, isolated DB.
- Dev/test strict compile, changed-file format, diff and local Markdown targets
  passed. Resolved TODO removed; no Req/Mint business transport calls remain.
- All implementation checkboxes complete. User authorized integration into main
  and the next patch release, v0.6.4. Existing release.yml owns version bump,
  archives, tag, GitHub release and Docker publication. Credentialed staging
  and a running-service switch remain NOT RUN.
