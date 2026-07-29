# Manifold Edge

`manifold_edge` owns the optional cloud-ingress deployment boundary: an
edge-only PostgreSQL Repo, versioned recipient snapshots, durable SMTP spool
records, signed pull API, nonce replay protection, acknowledgement tombstones,
and spool reconciliation.

It intentionally contains no mailbox projection, MIME parsing, security policy,
outbound provider, local webmail, IMAP, POP3, or direct outbound MX delivery.
