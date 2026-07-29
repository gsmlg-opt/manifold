# ADR 0006: Local-Pull Cloud Ingress Edge

- Status: Accepted
- Date: 2026-07-29

## Context

Some self-hosted installations cannot expose SMTP port 25 because of carrier
NAT, residential firewalls, dynamic addresses, or provider policy. Manifold
still needs to reject unknown recipients during SMTP and preserve the same
durability promise as direct local ingress.

The cloud boundary is exposed to the Internet and therefore has a different
trust model from Manifold's no-login local web interface.

## Decision

Ship an optional, separate `manifold_edge` release beginning in Release 0.2.
It has an edge-only PostgreSQL schema, a durable spool, the reusable SMTP
transport, and a signed synchronization API. It does not contain mailbox,
message projection, security, outbound, or local webmail applications.

The local installation publishes complete, versioned recipient-route snapshots.
The edge pins one valid snapshot for each SMTP transaction, rejects unknown
recipients at `RCPT TO`, and returns `250` only after its raw bundle and edge
delivery record are durable.

Synchronization is initiated by the local installation over HTTPS. Every API
request is signed and binds the installation identity, authority, method, path,
timestamp, nonce, and exact body digest. The request Host must match the signed
authority, redirects are disabled, and nonces remain persisted for the entire
signed-request validity window.

The local installation verifies raw size and SHA-256, imports through the
existing ingest acceptance transaction using a unique edge provenance key, and
then acknowledges the edge. The edge removes its ready spool only after the
acknowledgement commits. The acknowledged database row remains as the durable
idempotency tombstone. Spool cleanup first uses an atomic temporary tombstone so
an interrupted recursive removal can resume safely.

A permanent local integrity or provenance rejection is reported to the edge.
The edge removes that delivery from pull pages but retains its raw bundle for
operator recovery, allowing later deliveries to continue.

## Consequences

- Home networks need outbound HTTPS access only.
- Edge compromise exposes queued raw mail and routing identifiers, so deployment
  hardening and encryption remain mandatory.
- Snapshot expiry causes temporary SMTP rejection rather than false permanent
  recipient rejection.
- Pull, import, acknowledgement, and cleanup must all tolerate retries and
  crashes.
- The edge stores no long-term mailbox state and performs no MIME parsing,
  security policy, provider submission, or direct outbound MX delivery.
