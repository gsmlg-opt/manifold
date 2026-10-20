# Inline Mail Body Recovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Recognize inline MIME bodies and safely rebuild existing projections from archived raw messages.

**Architecture:** Keep existing alternative/related/mixed selection. Track the final text/html part paths internally and exclude those paths from attachment extraction. Protect valid stored projections and corrected receive times during versioned rebuilding; reuse the current reconciler and Oban worker.

**Tech Stack:** Elixir, Mail 0.5.2, Ecto/PostgreSQL, ExUnit, Phoenix LiveView, existing Oban jobs.

Approved scope: [design](../specs/2026-10-20-mail-inline-body-recovery-design.md), user approval on 2026-10-20. Implementation used `.trees/mail-inline-body` on `codex/mail-inline-body`; both were removed after integration. The commands below retain that historical execution context. Run future checks from the main project root without the worktree `cd`. HTML fidelity and public production deployment remain separate.

## Execution boundaries

- Parser worker owns `apps/manifold_mail/lib/manifold/mail/parser.ex` and `apps/manifold_mail/test/manifold/mail/parser_test.exs`.
- Projection worker owns `apps/manifold_mail/lib/manifold/mail/projector.ex` and `apps/manifold_mail/test/manifold/mail/projector_test.exs`.
- Parent owns ingest/reader integration tests, version configuration and documentation.
- Workers may edit their files in parallel. Parent coordinates Mix runs to avoid compilation/database races. New regression tests use `@tag :inline_body_regression` so baseline and new behavior can be run separately.
- Use the existing devenv shell from the project root, change directory into this worktree, unset `TEST_DATABASE_URL`, and set `POSTGRES_TEST_DB=manifold_mail_inline_body_test`. Dependency sources and build output are isolated; do not modify root dependencies or either lockfile.

## Task 1: Baseline and diagnostic regression

- [x] Fetch the exact locked dependencies in the isolated worktree with `mix deps.get --check-locked`; preserve `mix.lock`.
- [x] Run existing scoped tests with `--exclude inline_body_regression` before changing implementation.
- [x] Add minimal regression tests and run them before implementation. Confirm assertions fail because inline body fields are nil, valid projections are overwritten by fallback, or corrected `received_at` is cleared.

Canonical test command (run from project root):

```sh
devenv shell -- env -u TEST_DATABASE_URL POSTGRES_TEST_DB=manifold_mail_inline_body_test sh -c 'cd /home/gao/Workspace/gsmlg-opt/manifold/.trees/mail-inline-body && mix test apps/manifold_mail/test/manifold/mail/parser_test.exs apps/manifold_mail/test/manifold/mail/projector_test.exs apps/manifold_ingest/test/manifold/ingest_test.exs apps/manifold_web/test/manifold_web/mail_live_test.exs apps/manifold_web/test/manifold_web_test.exs --exclude inline_body_regression'
```

Expected baseline: zero failures. Dependency/setup errors are investigated without changing dependency versions. Scope-external test failures are reported without repair.

Baseline passed with seed 337349. RED seed 50917 reproduced all 13 parser failures, corrected receive-time loss, two failed-reparse guard failures and the Ingest state-path failure. Two new fixture setup mistakes (missing BlobStore expected_size and missing archive_delivery before security evaluation) were corrected without changing production code. RED integration rerun seed 849598 then reached the intended legacy-recovery and reader failures; genuine file-only fallback and raw-failure controls passed. Diagnostic logs: `/tmp/manifold-inline-body-red.log` and `/tmp/manifold-inline-body-red-integration.log` (local, untracked).

## Task 2: MIME body selection and attachment separation

- [x] Add parser cases for standalone inline plain/html, inline alternatives with/without filenames, empty filename/name fallback, competing alternatives, nested related roots, mixed siblings and explicit attachment subtrees.
- [x] Keep body selection order; distinguish explicit file attachments from inline text body candidates.
- [x] Carry `text_path` and `html_path` alongside internal body selection and update paths whenever alternatives replace a body. Single-part path is `1`; nested paths match existing `collect_leaves` numbering.
- [x] Select bodies once, then extract existing attachment candidates excluding only the final selected paths. Preserve unselected inline images/text resources.
- [x] Normalize each filename/name independently before precedence; preserve nonempty original names.
- [x] Run parser tests and inspect the diff for changes to limits, encoding or public structs.

The principal public behavior assertion is:

```elixir
assert {:ok, parsed} = Manifold.Mail.Parser.parse(raw_inline_alternative)
assert parsed.text_body == "Plain body"
assert parsed.html_body == "<p>HTML body</p>"
assert parsed.attachments == []
```

## Task 3: Safe existing-projection recovery

- [x] Construct a legacy projection fixture with nil bodies and two inline body attachments; rebuild from its archived raw using a newer explicit parser version.
- [x] Verify message/entry identity, read/star/folder/thread state, corrected receive time, no duplicate mail and removal of false attachments.
- [x] Under the existing delivery lock, reject replacing current `parse_state=parsed` with new fallback; rollback the transaction with a temporary error rather than changing processed delivery state.
- [x] Use the guard error contract below and preserve the underlying safe parse reason. Initial projection fallback remains supported.
- [x] Keep existing `received_at` when rebuilding a stored message, including provider imports whose initial source timestamp is intentionally nil.
- [x] Test missing/corrupt raw, parsing failure, transaction failure and repeated projection against the existing public entrypoints.

Guard contract:

```elixir
{:error,
 %Manifold.Core.Error{
   class: :temporary,
   reason: :reprojection_parse_failed,
   details: %{parse_error: "malformed_mime"}
 }}
```

The parse_error string records the actual classified reason, including limit/timeout reasons in their own cases; it never contains mail content. Stored versions and valid body/attachment rows remain unchanged.

## Task 4: Ingest and reader integration

- [x] In `apps/manifold_ingest/test/manifold/ingest_test.exs`, exercise `Ingest.project_delivery/2` on a previously processed delivery; assert temporary guard error, original reason, processed state and old projection version survive.
- [x] In `apps/manifold_web/test/manifold_web/mail_live_test.exs`, exercise genuine projected inline raw mail and assert iframe/body content, plain text escaping and empty fallback behavior. Preserve genuine attachments and their download links.
- [x] Retain existing controller coverage for CSP/sandbox, cross-mailbox access, quarantine and storage failures; do not change reader production code to infer bodies from attachments.
- [x] After regression tests pass, change only `parser_version: 5` to `parser_version: 6` in `config/config.exs` and explain the inline repair in its version comment. Keep sanitizer version 1.

## Task 5: Review and final scoped evidence

- [x] Run the five scoped test files from Task 1 without excluding the new tests. Existing security-resource tests remain included. No full umbrella suite or asset build is required.
- [x] Format changed Elixir files, then run `mix format --check-formatted` on those paths and strict test-environment compilation.
- [x] Review spec compliance, then code quality; fix task-owned findings and rerun only the affected checks.
- [x] Update the design, this checklist, feature reference and design index with actual counts, commands and limitations. Check whitespace and local document links.
- [x] Leave production replay/deployment marked NOT RUN. The configured version upgrade activates existing recovery jobs only after the change is deployed. Do not claim the linked production mail is repaired from local tests.

Production acceptance after a separately authorized deployment must check actual text/html API bodies, disappearance of the two false attachments, visible browser body, remaining stale projection count and classified failures. Existing attachment IDs may change during rebuilding.

## Final validation evidence

At the initial implementation checkpoint, work was complete locally on `codex/mail-inline-body`; no commit, push, release, deployment or production replay had been performed. The later authorized integration checkpoint below supersedes that operational status.

- Parser-only check after the scoped resource fixture correction: seed 248309, 26 tests, 0 failures.
- Actual immediate-deadline checks: seed 434418, no failures; exact `parser_timeout`, preserved projection snapshots and processed Ingest state. These use real approximately 2 MiB raw and zero timeout, with no sleep, retry or production hook. They are deadline-boundary coverage, not scheduler-independent timing proof.
- Final scoped suite: seed 792712; mail 45, ingest 57, web 31; **133 tests, 0 failures**, no exclusions.
- Changed Elixir files formatted; scoped format check and `MIX_ENV=test mix compile --warnings-as-errors` exited 0.
- Independent spec review: PASS after adding explicit timeout coverage. Independent code quality review: APPROVE, no actionable findings.
- `git diff --check`: PASS. All 96 local Markdown targets across the four changed documents exist. Lockfiles are unchanged.

Final command (from the main project root):

```sh
devenv shell -- env -u TEST_DATABASE_URL MIX_ENV=test POSTGRES_TEST_DB=manifold_mail_inline_body_test sh -c 'cd /home/gao/Workspace/gsmlg-opt/manifold/.trees/mail-inline-body && mix format --check-formatted apps/manifold_mail/lib/manifold/mail/parser.ex apps/manifold_mail/test/manifold/mail/parser_test.exs apps/manifold_mail/lib/manifold/mail/projector.ex apps/manifold_mail/test/manifold/mail/projector_test.exs apps/manifold_ingest/test/manifold/ingest_test.exs apps/manifold_web/test/manifold_web/mail_live_test.exs config/config.exs && mix compile --warnings-as-errors && mix test apps/manifold_mail/test/manifold/mail/parser_test.exs apps/manifold_mail/test/manifold/mail/projector_test.exs apps/manifold_ingest/test/manifold/ingest_test.exs apps/manifold_web/test/manifold_web/mail_live_test.exs apps/manifold_web/test/manifold_web_test.exs'
```

The initial GREEN attempt found an additional, pre-existing binary charset conversion in the new PNG role fixture: mail 0.5.2 supplies us-ascii, and the existing Charset callback replaces invalid bytes. No encoding code was changed; the role regression uses valid ASCII SVG with exact byte assertions. Binary attachment integrity is recorded as a separate follow-up in the feature reference. Initial local implementation checks stayed within the approved five-file scope; later integration CI is recorded below.

## Authorized integration checkpoint

- User subsequently authorized worktree merge, commit/push, devenv restart and the next release. Repair commit `590556f28850bc7005198b2e96272e5577f1de9a` was fast-forwarded into `main` and pushed; the task worktree and branch were removed. Earlier root design drafts remain preserved in the named stash `preserve inline-body design drafts before main integration`.
- Merged-main validation: seed 947535, **133 tests, 0 failures**, scoped formatting and strict test compilation passed; `mix.lock` is unchanged.
- Source workflows passed at `590556f`: CI `39449532991`, full ExUnit `39449533388` (**1,597 tests, 0 failures, no exclusions or skips**) and TLS backends `39449533651`.
- Local restart passed at 2026-10-20 15:38:37 UTC: PostgreSQL accepts connections, both devenv services ready, web and API health return 200, runtime metadata confirms source `590556f`.
- The first native PostgreSQL restart raced its previous shutdown and hit the existing PID file. Recovery stopped app and database, confirmed the old postmaster exited, started PostgreSQL and verified readiness before starting the app. No PID files were deleted and no runtime code was changed.
- Initial local recovery rebuilt 500 messages to parser 6/parsed; stale projections decreased from 39,497 to 38,997. Message count 39,497 and entry count 39,499, plus aggregate identity/timestamp/user-state fingerprints, are unchanged. Existing 251 fallback rows are unchanged; two parser-6 jobs were retryable. Complete backfill was not awaited.
- Local evidence: `/tmp/manifold-inline-body-main-validation.log`, `/tmp/manifold-v066-source-exunit.log` and `/tmp/manifold-v066-runtime-evidence/{pre,post,comparison,readiness}.json`. Runtime snapshots contain counts/fingerprints, not message content or credentials; these temporary files are not release assets.
- The original target message is absent locally. Public production deployment and its API/browser acceptance remain NOT RUN. Next authorized step: dispatch the existing release workflow for v0.6.6 and verify both archives and container images.

Production acceptance remains NOT RUN: after a separately authorized deployment, verify actual API text/HTML, removal of false attachments, browser readability and stale-projection/failure counts. HTML fidelity remains separate.
