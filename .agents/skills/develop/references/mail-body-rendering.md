# Mail body recognition and recovery

- Date: 2026-10-20.
- Status: merged and pushed to `main` as `590556f`; local services restarted and initial recovery verified. v0.6.6 publication is the next authorized step; public production deployment and recovery remain NOT RUN.
- Scope selected by the user: repair body recognition and recover existing messages; design HTML fidelity separately.
- Design: [Inline body recognition and recovery](../../../../docs/superpowers/specs/2026-10-20-mail-inline-body-recovery-design.md).

## Ownership

- `manifold_mail/Parser`: MIME tree selection, body eligibility and attachment extraction.
- `manifold_mail/Projector`: verified raw reads, parser/sanitizer versions and atomic projection replacement.
- `manifold_ingest/Reconciler`: existing stale-projection scheduling.
- `manifold_web/MailLive.Index`: HTML iframe, escaped plain text and empty-body fallback.
- `manifold_web/MessageBodyController` and `AttachmentController`: mailbox-scoped body and download resources.

## Confirmed baseline defect

`Parser.attachment?/1` treats every `Content-Disposition: inline` part as an attachment. Consequently an inline text/plain and text/html alternative produces nil bodies and two downloadable attachments. Production REST metadata and a local Parser control experiment reproduced this behavior on the v0.6.5 source baseline.

## Implementation

Preserve existing alternative/related/mixed selection, distinguish body eligibility from attachment collection, and carry final text/html leaf paths internally to prevent duplicate body attachments. Inline text/plain and text/html are eligible even with a filename; explicit attachment subtrees remain excluded from body selection. Only final selected paths are excluded from existing attachment candidates, so superseded inline alternatives and other inline resources remain downloadable. Blank filename/name values are normalized independently before filename-to-name fallback; nonempty original names are preserved.

Configured parser_version is now 6; sanitizer_version remains 1. After deployment, the existing reconciler schedules old projections using archived raw. Under the delivery advisory lock and fresh message reread, current projections return first; replacing an existing parsed projection with fallback rolls back with temporary `reprojection_parse_failed` and safe `%{parse_error: classification}` details. The existing Ingest/Oban retry path retains the processed delivery state. First-projection fallback remains supported. Replacement preserves existing received_at for every source kind, plus message/entry identity and read/star/folder/thread state. Existing attachment rows are replaced during successful reprojection, so old download URLs may expire.

## Constraints

No schema migration, provider refetch, resend, new API contract or frontend renderer change. Sanitizer, CSP, sandbox, mailbox and quarantine boundaries are unchanged. HTML styles/images remain blocked in this repair. Missing/corrupt raw and failed reparse preserve the existing projection. No public production deployment or replay was performed.

## Verification

- PASS: authenticated browser reproduction; read-only production conversation/body/attachment API inspection; local Parser comparison of absent, inline and attachment dispositions.
- PASS: red-before-green parser, projection and reader failures; legacy empty-body/two-inline-attachment recovery; identity/state/received_at/idempotency; raw failures, transaction rollback, fresh reread guard; Ingest processed-state preservation and successful retry; HTML iframe, escaped plain text, file-only fallback and real downloads.
- PASS: final five-file scoped suite, seed 792712: manifold_mail 45, manifold_ingest 57, manifold_web 31; **133 tests, 0 failures**. Existing resource tests include body/attachment security boundaries.
- PASS: changed Elixir files formatted and `mix format --check-formatted`; `MIX_ENV=test mix compile --warnings-as-errors`; `git diff --check`.
- PASS: actual zero-timeout checks over approximately 2 MiB valid raw assert `parser_timeout` without retrying or accepting alternate outcomes. These exercise the immediate-deadline boundary; they do not prove scheduler-independent timing. The reread fixture changes state inside the existing fault callback; it is not a full concurrent-writer test.
- PASS (integration checkpoint): merged-main scoped suite, seed 947535, **133 tests, 0 failures**, scoped formatting and strict test compilation. Source CI, TLS backends and remote full ExUnit suite passed; the full suite contains **1,597 tests, 0 failures, no exclusions or skips**.
- PASS (local runtime, 2026-10-20 15:38:37 UTC): PostgreSQL accepts connections; devenv services ready; web and API health return 200 on source `590556f`. Initial reconciliation rebuilt 500 messages as parser 6/parsed; stale rows decreased from 39,497 to 38,997. Message count 39,497 and mailbox-entry count 39,499 are unchanged, as are aggregate identity/timestamp/user-state fingerprints. Existing 251 fallback rows are unchanged; two parser-6 jobs were retryable. This checkpoint does not establish complete recovery.
- NOT RUN: actual public production raw replay, deployment and production recovery. The reported target message is absent from the local database, so local recovery cannot establish that message's acceptance. No frontend assets changed, so no local asset build was required.

Run from the main project root using `devenv shell`, unset `TEST_DATABASE_URL` and set `POSTGRES_TEST_DB=manifold_mail_inline_body_test`. The implementation worktree and branch were removed after integration. Historical worktree commands and RED evidence are in the [implementation plan](../../../../docs/superpowers/plans/2026-10-20-mail-inline-body-recovery.md).

## Follow-ups

After a separately authorized deployment, verify actual message API bodies, disappearance of the two false attachments, visible browser body and remaining stale-projection/failure counts. Queue progress alone is not acceptance.

The new resource-role fixture also exposed a pre-existing binary decoding issue: mail 0.5.2 defaults parameterless content types to `us-ascii`, then the existing Charset callback can replace non-ASCII image bytes. This repair does not change encoding. The role/path test uses valid ASCII SVG and retains an exact byte assertion. Dependency source is DockYard/elixir-mail, outside the repository's mandatory internal issue organizations; binary attachment integrity needs separate investigation.

Design safe HTML/CSS/image fidelity in a separate follow-up.
