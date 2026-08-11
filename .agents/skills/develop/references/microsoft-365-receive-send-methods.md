# Microsoft 365 Receive and Send Methods

## Feature

- **Name**: Microsoft 365 receive and send methods
- **Date**: 2026-08-11
- **Owner/Requestor**: Repository maintainer
- **Status**: `in-progress` (design approved; implementation not started)

## Scope

- **Apps touched**: Design targets `manifold_data`, `manifold_connectors`,
  `manifold_outbound`, `manifold_mail`, and `manifold_web`.
- **Files changed**: Design stage adds this reference and
  `docs/superpowers/specs/2026-08-11-microsoft-365-receive-send-methods-design.md`.
- **Reason for change**: Preserve the real Microsoft Graph receiver, add
  least-privilege Graph sending, and converge Microsoft's authoritative Sent
  Items copy into a local Sent folder.

## Module ownership

- `manifold_data`: Own migrations and database constraints for shared Microsoft
  authorization, send methods, Sent folders, and provider submissions.
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

- **Database/migration impact**: Rebase and renumber the Gmail shared-auth
  migration, backfill existing Microsoft OAuth data without invalidating AES-GCM
  associated data, add Microsoft send support, create one Sent folder per
  mailbox, persist immutable provider MIME payloads for exact retries, and allow
  successful provider submissions without a provider message ID.
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

- **What changed**: The approved design is recorded; production code is not yet
  changed.
- **Why this approach**: Extending the post-Gmail shared OAuth and outbound
  foundation avoids duplicate token stores and preserves the implemented Graph
  receive path. Direct `sendMail` keeps permissions narrower than a
  draft-and-reconcile design. Projected Sent and Send activity remain separate
  so provider mail and outbound lifecycle records do not require a merge or
  deduplication layer.
- **Alternatives considered**: Independent Microsoft send authorization and a
  complete combined-connector rewrite were rejected. Draft-then-send was
  rejected because it requires `Mail.ReadWrite`.
- **Rollback notes**: Design-only commit is documentation. Implementation must
  retain legacy receive state and queued Resend provider snapshots so a deploy
  does not silently reroute existing work.

## Validation

- `mix test apps/manifold_data/test`
- `mix test apps/manifold_connectors/test`
- `mix test apps/manifold_outbound/test`
- `mix test apps/manifold_mail/test`
- `mix test apps/manifold_web/test`
- `mix format --check-formatted`
- `mix compile --warnings-as-errors`
- `mix duskmoon_bundler.js.check` (only if implementation changes JavaScript)
- **Result summary**: Design-only stage; implementation checks have not been
  run. The written design requires these scoped checks before completion.

## Post-task

- **Follow-ups**: User review of the committed specification, then a detailed
  implementation plan. Implementation must keep this reference current with
  actual file ownership and validation results.
- **Opened issues / TODOs**: None. No upstream dependency gap was identified
  during design.
- **Docs updated**:
  `docs/superpowers/specs/2026-08-11-microsoft-365-receive-send-methods-design.md`.
