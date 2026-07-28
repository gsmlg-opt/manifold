# ADR 0003: PostgreSQL And Oban

PostgreSQL is the authoritative metadata store. Ecto owns schema access through application contexts, while migrations are centralized in `manifold_data`.

Oban is used for durable background archival because jobs are inserted transactionally with accepted deliveries and can resume after restarts.
