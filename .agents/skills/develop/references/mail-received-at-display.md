# Feature/Task Update Template

## Feature

- **Name**: mail-received-at-display
- **Date**: 2026-08-06
- **Owner/Requestor**: product / inbox UX
- **Status**: `done`

## Scope

- **Apps touched**: `manifold_data`, `manifold_mail`, `manifold_connectors`, `manifold_web`, `manifold_api`
- **Files changed**: messages.received_at migration; projector/mailbox/view; IMAP INTERNALDATE; EAS DateReceived; mail LiveView + API JSON/GraphQL
- **Reason for change**: Inbox list/detail must show mailbox receive time (like QQ Mail), not the RFC `Date` header send time

## Module ownership

- `manifold_data`: migration `20260806000500_add_message_received_at.exs`
- `manifold_mail`: `Message.received_at`, projector write from `InboundSource.received_at`, list/sort `COALESCE(received_at, sent_at, inserted_at)`, `View.Message.received_at`
- `manifold_connectors`: IMAP `UID FETCH (FLAGS INTERNALDATE)`; EAS Sync `DateReceived`
- `manifold_web`: conversation message timestamp uses `received_at`
- `manifold_api`: REST/GraphQL expose `received_at`
- `manifold_accounts`:
- `manifold_smtp`:
- `manifold_outbound`:
- `manifold_ingest`: still owns delivery `received_at` as transport truth
- `manifold_storage`:
- `manifold_cloud`:
- `manifold_edge`:
- `manifold_core`:
- `manifold_security`:

## Design and data impact

- **Database/migration impact**: nullable `messages.received_at`
- **API or background-job impact**: message payloads gain `received_at`; list ordering prefers receive time
- **Config / env impact**: none
- **Security / auth / trust-boundary impact**: none

## Implementation notes

- **What changed**: Persist provider/mailbox receive time on projected messages; IMAP/EAS now supply it; UI sorts and displays it with fallback to `sent_at`. Sync upserts write `provider_received_at` through to `messages.received_at`. FLAGS scan covers boosted UIDs via `max(last_uid, boosted_until)`.
- **Why display looked stuck**: Historical IMAP imports had null `messages.received_at` / null `sent_at` for some rows, so the list fell back to sync `inserted_at` (clustered minutes). Also FLAGS repair only scanned `UID <= last_uid`, skipping UNSEEN-boosted high UIDs.
- **Why recent mail was missing**: Bootstrap walked `last_uid` upward from old history while QQ tip UIDs were ~12k+. Read recent mail is not UNSEEN-boosted, so it waited for full historical crawl. Fix: dual watermark — `last_uid` history ascending + `recent_until` newest-first catch-up when `pending > page_size` beyond the next history page. Priority: UNSEEN boost → recent catch-up → FLAGS repair → history.
- **Data repair applied** (gsmlg@qq.com): backfilled Date→`sent_at` where possible; FLAGS/INTERNALDATE rescan + high-UID INTERNALDATE fetch; then recent catch-up imported DeepSeek / QQ团队 / Vultr Amsterdam etc. Inbox ~2246 and climbing while `recent_until` walks down from tip.
- **Alternatives considered**: Join `inbound_deliveries` at query time (cross-app schema coupling); QQ-style relative labels (out of scope)
- **Rollback notes**: Drop column; revert connector FETCH/parse and UI field

## Validation

- `mix ecto.migrate`
- Scoped mail/connectors tests green; live QQ mailbox backfilled + recent catch-up
- **Result summary**: inbox top matches QQ recent mail (QQ邮箱团队 / DeepSeek / Vultr Amsterdam) ordered by real receive time

## Post-task

- **Follow-ups**: historical crawl continues via `last_uid` until full mailbox (~7607); total count gap vs QQ is expected until bootstrap finishes
- **Opened issues / TODOs**: none
- **Docs updated**: this reference
