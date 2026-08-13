# Microsoft 365 Receive and Send Methods

## Feature

- **Name**: Microsoft 365 receive and send methods
- **Date**: 2026-08-11
- **Owner/Requestor**: Repository maintainer
- **Status**: `implemented` (Tasks 1-14 are complete; credentialed external
  staging was not run because Microsoft credentials are unavailable)

## Scope

- **Apps touched**: `manifold_data`, `manifold_connectors`,
  `manifold_account_lifecycle`, `manifold_outbound`, `manifold_mail`, and
  `manifold_web`.
- **Files changed**: Sent-folder/shared-authorization/payload migrations;
  connector OAuth, Microsoft Graph, folder-mapping, sync, and lifecycle tests;
  outbound immutable MIME, Graph transport, submission and job paths; Mail
  projection; Web method setup and Sent/Send activity routes; ADR/operator docs.
- **Reason for change**: Preserve the real Microsoft Graph receiver, add
  least-privilege Graph sending, and converge Microsoft's authoritative Sent
  Items copy into a local Sent folder.

## Module ownership

- `manifold_data`: `20260812000100_add_sent_system_folders.exs`,
  `20260812000200_add_shared_microsoft_authorizations.exs`, and
  `20260812000300_add_microsoft_provider_payloads.exs` own Sent, shared auth, and
  immutable payload constraints/backfills.
- `manifold_accounts`: Own canonical account address and active-account
  lifecycle checks used during OAuth and queueing.
- `manifold_connectors`: Own Microsoft OAuth, identity binding, encrypted
  credentials, serialized refresh, receive sync, folder mapping, and token
  checkout.
- `manifold_mail`: Own the provider-neutral Sent system folder and projected
  mailbox-entry placement.
- `manifold_web`: Own receive/send setup, incremental consent, reconnect,
  compose blocking, projected Sent navigation, renamed Send activity routes,
  and legacy outbound-route redirects.
- `manifold_api`: No behavior change is planned.
- `manifold_smtp`: No behavior change is planned.
- `manifold_outbound`: Own send-method snapshots, deterministic MIME, the Graph
  adapter, provider outcomes, and uncertainty.
- `manifold_ingest`: Existing external-import boundary remains unchanged.
- `manifold_storage`: Existing raw and attachment storage remains unchanged.
- `manifold_cloud`: No behavior change is planned.
- `manifold_edge`: No behavior change is planned.
- `manifold_core`: No behavior change is planned.
- `manifold_security`: Existing projected-message security processing remains
  unchanged.

## Design and data impact

- **Database/migration impact**: Existing Microsoft receive IDs become shared
  authorization IDs so AES-GCM associated data remains valid. Cursors, remote
  mappings, imported history, and jobs continue to reference the preserved
  receive method. Each mailbox gains exactly one Sent system folder. Gmail,
  SMTP, and Microsoft queue rows persist immutable provider MIME; a database
  trigger rejects snapshot mutation and permits only the one bounded legacy
  payload fill transition. Microsoft success allows a nil provider message ID.
- **API or background-job impact**: Keep five-minute Graph delta polling; expose
  serialized credential checkout to outbound; route queued mail through direct
  MIME `/me/sendMail`; resolve and persist well-known folder IDs; repair existing
  Graph folder placement during normal sync; no webhook or new recurring job is
  planned.
- **Config / env impact**: Reuse the existing Microsoft client ID, client secret,
  `organizations` tenant, endpoint overrides, callback, and connector encryption
  key.
- **Security / auth / trust-boundary impact**: Use delegated `Mail.Read` and
  `Mail.Send`, exact sender/Graph-address binding, PKCE, encrypted tokens, and no
  credential or message content in logs, telemetry, metadata, or job args.

## Implementation notes

- **What changed**: Microsoft receive/send share OAuth lifecycle, scope upgrades,
  token refresh and reconnect state. Graph resolves well-known folder IDs and
  repairs localized historical placement without cursor replacement or raw
  fetches. Queueing freezes exact MIME; direct Graph `sendMail` records bodyless
  `202` acceptance and conservative uncertainty. Projected Sent and outbound
  Send activity have distinct models/routes. Account-disable fences and safe
  fixed-code telemetry cover the new state. Account purge drains provider
  submissions before connector send methods and removes target Oban rows in
  bounded, account-scoped passes after fencing executing work.
- **Why this approach**: Extending the post-Gmail shared OAuth and outbound
  foundation avoids duplicate token stores and preserves the implemented Graph
  receive path. Direct `sendMail` keeps permissions narrower than a
  draft-and-reconcile design. Projected Sent and Send activity remain separate
  so provider mail and outbound lifecycle records do not require a merge or
  deduplication layer.
- **Alternatives considered**: Independent Microsoft send authorization and a
  complete combined-connector rewrite were rejected. Draft-then-send was
  rejected because it requires `Mail.ReadWrite`.
- **Rollback notes**: The cutover is non-rolling. Migration rollback guards
  refuse unsafe live Microsoft authorizations or immutable payload state. Legacy
  receive state and Resend provider snapshots are not silently rerouted.

## Validation

- `mix test apps/manifold_data/test`
- `mix test apps/manifold_connectors/test`
- `mix test apps/manifold_outbound/test`
- `mix test apps/manifold_mail/test`
- `mix test apps/manifold_web/test`
- `mix test apps/manifold_account_lifecycle/test`
- `mix format --check-formatted`
- `mix compile --warnings-as-errors`
- `mix duskmoon_bundler.js.check` (only if implementation changes JavaScript)
- **Result summary**: Formatting and strict compilation passed. The final scoped
  suites passed: Mail 69, Connectors 349, Outbound 172, Web 104, Account
  Lifecycle 37, and Data 15 (746 tests total, zero failures). Focused acceptance
  coverage proves legacy receive continuity, well-known folder repair, one Sent
  folder per mailbox, incremental `Mail.Send` without `Mail.ReadWrite`, identity
  isolation, immutable provider/MIME selection, exact direct-MIME Graph
  submission, bodyless `202` acceptance, conservative retry/uncertainty fencing,
  authoritative Sent import, distinct Sent/Send surfaces, shared revocation and
  reconnect behavior, lifecycle cleanup, and redaction of secrets/message data.
  The disposable-database clean up/down/up and realistic legacy migration
  rehearsals passed, including ciphertext/AAD preservation, cursor/job/history
  continuity, localized Sent repair without network/raw fetch, and one-time
  immutable Gmail/SMTP payload fill. External staging was not run: credentials
  unavailable.
- **Acceptance matrix**:
  1. Pass — legacy Microsoft receive preserves authorization, cursors, history,
     mappings, and queued jobs.
  2. Pass — localized folders classify and repair by well-known folder ID.
  3. Pass — every mailbox has exactly one usable system Sent folder.
  4. Pass — receive-only authorization adds `Mail.Send` without
     `Mail.ReadWrite`.
  5. Pass — distinct identities isolate and subject/address mismatches reject.
  6. Pass — queue snapshots select Microsoft without an implicit Resend path.
  7. Pass — exact MIME reaches `/me/sendMail`; bodyless `202` records acceptance
     without claiming delivery.
  8. Pass — only throttling/proven pre-dispatch failures retry; ambiguous
     outcomes never resend and actual provider calls stop at eight.
  9. Pass — authoritative Sent items import once when receive exists.
  10. Pass — projected Sent and Send activity remain separate; old URLs redirect.
  11. Pass — revocation pauses both directions and one-direction disconnect
      preserves the other.
  12. Pass — secrets and message data are absent from logs, telemetry, metadata,
      activity records, and job args.
  13. Pass — all scoped tests, formatting, and strict compilation pass.

## Post-task

- **Follow-ups**: Run the credentialed staging smoke checklist when two matching
  non-production Microsoft 365 work/school identities and app credentials are
  available.
- **Opened issues / TODOs**: No local or upstream implementation blocker remains.
- **Docs updated**: design/spec/plan, ADR 0007, ADR 0010, ADR 0011,
  `docs/DESIGN.md`, `README.md`, and this/Gmail feature references.
