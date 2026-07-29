# Manifold Cloud

`manifold_cloud` is the local side of optional cloud ingress. It publishes
recipient snapshots, pulls pending edge deliveries over signed HTTPS, streams
raw bytes into the local durable spool, imports through `Manifold.Ingest`, and
acknowledges only after PostgreSQL acceptance commits.

Oban jobs provide retry and restart recovery. The edge never calls into the
local installation.
