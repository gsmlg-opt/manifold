# ADR 0005: Raw Message Source Of Truth

The accepted RFC 5322 message bytes are preserved as immutable raw `.eml` content. Parsed headers, mailbox projections, search data, and security decisions are derived from that source and may be rebuilt.

SMTP envelope metadata remains separate from sender-controlled headers.
