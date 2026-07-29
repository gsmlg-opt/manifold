# Manifold Milestone 5 Implementation Plan

**Status:** Completed

## Scope

Milestone 5 adds an optional cloud ingress edge for installations that cannot
receive Internet SMTP directly:

1. Build a separate `manifold_edge` release.
2. Publish versioned recipient-route snapshots from the local installation.
3. Reject unknown recipients at the edge during `RCPT TO`.
4. Durably spool accepted raw messages at the edge before SMTP `250`.
5. Let the local installation pull accepted deliveries over an authenticated
   HTTP protocol.
6. Import each edge delivery through the existing local ingest contract.
7. Acknowledge idempotently and remove the edge spool only after local durable
   acceptance.
8. Expose bounded edge and local synchronization operations views.

This milestone does not add outbound SMTP, an Internet-facing mailbox API,
provider-specific mail synchronization, MIME processing at the edge, or
long-term mailbox state at the edge.

## Applications And Releases

Add:

```text
manifold_edge
  -> manifold_core + manifold_storage + manifold_smtp

manifold_cloud
  -> manifold_core + manifold_data + manifold_accounts + manifold_ingest

manifold_smtp
  -> manifold_core
```

`manifold_smtp` becomes transport-only and receives configured resolver and
acceptance modules. The local release configures `Manifold.Accounts` and
`Manifold.Ingest`; the edge release configures `Manifold.Edge`.

The `manifold` release adds `manifold_cloud`. The separate `manifold_edge`
release contains only core, storage, edge persistence/API, and SMTP
applications. `manifold_edge` owns a separate Repo and edge-only migrations;
it does not reuse `Manifold.Repo` or install local mailbox tables.
It does not start the local webmail, MIME projection, security, outbound, or
mailbox applications.

## Recipient Snapshot

`Manifold.Accounts.recipient_snapshot/0` returns a public immutable projection:

- Schema version, expiry, and a monotonically persisted revision.
- Active domains and plus-addressing policy.
- Exact active mailbox routes.
- Exact active alias routes with active mailbox targets.
- Per-route plus-addressing policy.
- Local domain and mailbox IDs needed by frozen delivery routes.
- SHA-256 digest over canonical JSON.

Account route mutations bump the routing revision in the same database
transaction. The local cloud app publishes snapshots with a signed `PUT`. The edge persists
every accepted revision and resolves recipients from the latest committed
snapshot. Repeated identical revisions are idempotent; stale conflicting
revisions are rejected. An absent or expired snapshot produces a temporary
SMTP rejection, never a false unknown-recipient response.

## Edge Acceptance

The edge SMTP callback uses the same thin session contract as local SMTP:

1. Parse and normalize the envelope.
2. Resolve `RCPT TO` from the current persisted route snapshot.
3. Freeze accepted local mailbox routes.
4. Write and fsync the existing spool bundle layout.
5. Insert one edge-delivery row after the bundle reaches `ready/`.
6. Return `250` only after the row commits.

No MIME parsing, security evaluation, provider call, or mailbox projection runs
at the edge.

## Pull Protocol

Versioned endpoints:

```text
PUT  /api/v1/route-snapshots
GET  /api/v1/deliveries
GET  /api/v1/deliveries/:edge_delivery_id/raw
POST /api/v1/deliveries/:edge_delivery_id/acknowledgements
POST /api/v1/deliveries/:edge_delivery_id/failures
GET  /api/v1/status
```

Every API request uses HMAC-SHA-256 over version, installation identity,
method, authority/path, timestamp, nonce, and body digest. Timestamps have a
bounded skew, and consumed nonces remain persisted for the request's entire
validity window. Signatures are compared in constant time, request Host must
match the signed authority, redirects are disabled, and authenticated responses
are marked `no-store`. HTTPS is mandatory in production; HMAC is not a
substitute for transport encryption. Runtime configuration requires a shared
secret containing at least 32 bytes.

Delivery metadata contains frozen transport routes and raw integrity metadata,
but never an edge filesystem path. Raw bytes are returned only by the signed
raw endpoint.

## Local Import

The local pull worker:

1. Lists ready edge deliveries.
2. Fetches and verifies exact raw bytes against size and SHA-256.
3. Calls an idempotent external-ingest API using a trusted deterministic ingest
   ID derived from the edge delivery ID.
4. Persists the local delivery mapping.
5. Acknowledges the edge only after local acceptance commits.
6. Reuses the durable local mapping when acknowledgement must be retried.

Retry after any crash reuses the same edge ID and local ingest ID. It may not
create another accepted local delivery. A permanent integrity or provenance
failure is reported to the edge, which excludes that delivery from subsequent
pull pages while retaining its raw bundle for operator recovery. Processing
continues with later deliveries.

## Reconciliation

Edge reconciliation:

- Ready bundle plus edge row: keep available for pull.
- Acknowledged row plus remaining bundle: verify then clean up.
- Ready row plus missing bundle: record an operational failure; restore it to
  ready if the verified bundle reappears.
- Transient filesystem status errors: record the error without changing the
  delivery out of ready.
- Ready bundle without edge row: retain, then move to failed after policy.
- Interrupted acknowledged cleanup: resume from a deterministic cleanup
  tombstone.

Local reconciliation retries route publication, pulls, and acknowledgements
through durable Oban jobs. PubSub is notification only.

## Crash Boundaries

Tests cover:

1. Edge spool ready before edge database commit.
2. Edge database commit before local pull.
3. Raw fetch interruption before local acceptance.
4. Local acceptance commit before local import mapping.
5. Local mapping commit before edge acknowledgement.
6. Edge acknowledgement commit before spool cleanup.
7. Repeated pull, import, and acknowledgement.
8. Route publication retry, replay, stale revision, and invalid signature.
9. Permanent poison-delivery isolation without blocking later deliveries.
10. Transient spool errors, verified restoration, and resumable cleanup.
11. Future-clock nonce retention for the full signature validity window.

The central invariant is that the edge deletes raw mail only after durable local
acceptance, and local retry never duplicates an edge delivery.

## Verification

- Fresh migrations for local and edge release data.
- Pure route-snapshot and signature tests.
- Edge SMTP tests over real TCP.
- Signed HTTP API tests without Internet services.
- Edge SMTP, signed API, local streamed import, and mailbox acceptance tests.
- Release builds for `manifold` and `manifold_edge`.
- Full format, warnings-as-errors compile, tests, assets, and responsive browser
  checks.

Completed verification:

- Local migrations: 9 migrations from an empty PostgreSQL database.
- Edge migrations: 1 edge-only migration from an empty PostgreSQL database.
- Umbrella tests: 287 tests, 0 failures.
- Production assets and both release artifacts built successfully.
- Standalone edge release served the signed API and SMTP on real sockets.
- Edge release composition contains only Core, Storage, Edge, and SMTP Manifold
  applications; its boot script starts Edge before SMTP.
- `/cloud` was checked at 1440x900 and 390x844 with no overflow, overlap, or
  browser console errors.
