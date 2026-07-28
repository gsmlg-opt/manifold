# ADR 0004: Managed Outbound Only

Manifold will not implement direct outbound delivery to recipient MX servers. Future outbound work must go through a managed provider adapter that owns Internet retry, reputation, DKIM signing, bounce processing, and complaint feedback.
