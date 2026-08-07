# Feature/Task Update Template

## Feature

- **Name**: mail-received-at-display
- **Date**: 2026-08-07
- **Owner/Requestor**: product / inbox UX
- **Status**: `done`

## Scope

- **Apps touched**: `manifold_data`, `manifold_mail`, `manifold_connectors`, `manifold_web`, `manifold_api`, `manifold_ingest`
- **Files changed**: messages.received_at migration; projector/mailbox/view; IMAP INTERNALDATE; EAS DateReceived; mail LiveView + API JSON/GraphQL; provider_import projection + sync repair
- **Reason for change**: Inbox list/detail must show mailbox receive time (like QQ Mail), not sync/fetch time or only the RFC `Date` header

## Module ownership

- `manifold_data`: migration `20260806000500_add_message_received_at.exs`
- `manifold_mail`: `Message.received_at`, projector leaves nil for `provider_import`, `Mail.set_received_at/2` + `Mail.clear_received_at/1`, list/sort `COALESCE(received_at, sent_at, inserted_at)`
- `manifold_connectors`: IMAP `UID FETCH (FLAGS INTERNALDATE)`; EAS Sync `DateReceived`; sync repair on each account sync; ApplyRemoteState applies `provider_received_at`
- `manifold_ingest`: passes `delivery.source_kind` into `InboundSource`
- `manifold_web`: conversation message timestamp uses `received_at`
- `manifold_api`: REST/GraphQL expose `received_at`

## Design and data impact

- **Database/migration impact**: nullable `messages.received_at`
- **API or background-job impact**: message payloads gain `received_at`; list ordering prefers receive time
- **Config / env impact**: none
- **Security / auth / trust-boundary impact**: none

## Implementation notes

- **What changed**: Persist provider/mailbox receive time on projected messages; IMAP/EAS supply it; UI sorts and displays with fallback to `sent_at`.
- **Why display showed sync time**: `Sync.external_source` used `provider || now` for ingest. Projector copied that onto `messages.received_at`, so batch fetch stamped many mails with the same minute.
- **Fix (2026-08-07)**:
  1. Projector sets `messages.received_at = nil` when `source_kind == "provider_import"`.
  2. `ApplyRemoteState` / upsert call `Mail.set_received_at/2` only when `provider_received_at` is known.
  3. Each sync runs `repair_received_at/1`: apply known provider times; clear placeholders when provider time is still missing (UI falls back to Date/`sent_at`).
- **Ingest note**: `inbound_deliveries.received_at` may still be sync time when provider time is absent (required for accept); that value must not drive mailbox display.
- **Data repair**: next sync of an affected account clears fetch-time placeholders and rewrites from `provider_received_at` / INTERNALDATE FLAGS scan.
- **Alternatives considered**: Join `inbound_deliveries` at query time (cross-app coupling); QQ-style relative labels (out of scope)

## Validation

- `mix test apps/manifold_connectors/test/manifold/connectors/sync_test.exs`
- `mix test apps/manifold_connectors/test/manifold/connectors/sync_imap_test.exs`
- `mix test apps/manifold_connectors/test/manifold/connectors/sync_eas_test.exs`
- `mix test apps/manifold_mail/test/manifold/mail/projector_test.exs`
- **Result summary**: provider time applied after projection; missing provider time leaves nil and UI uses Date; historical placeholders repaired on sync

## Post-task

- **Follow-ups**: trigger a sync for mailboxes that still show clustered fetch timestamps (e.g. zdns.cn)
- **Opened issues / TODOs**: none
- **Docs updated**: this reference
