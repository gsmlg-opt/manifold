# Documentation progress tracking

- Date: 2026-10-13.
- Status: done.
- Scope: documentation navigation, development snapshot and remaining-work
  classification. No application, migration, configuration or provider changes.

## Ownership

- `docs/README.md`: documentation entry point and historical milestone index.
- `docs/PROGRESS.md`: reviewed source baseline, implemented capabilities,
  acceptance gaps, engineering follow-ups and optional product scope.
- `docs/DESIGN.md`: current architecture and application boundaries.
- `docs/MILESTONE_*_PLAN.md`: original milestone scopes and dated evidence;
  current-state notes link later superseding implementations.
- `docs/superpowers/README.md`: feature plan/specification and maintenance index.
- `docs/ICLOUD.md` and `docs/OAUTH_SETUP.md`: current operator guides.
- Owning develop references and acceptance files: implementation constraints,
  module ownership and dated validation results.

## Maintenance constraints

Keep current behavior separate from historical execution steps. Unchecked old
plan steps do not prove a feature is absent; do not bulk-check them from module
existence. Preserve dated failures and missing verification even when a later
checkpoint supersedes them. A version tag in the local checkout does not prove
publication or deployment readiness.

Record real-service reads separately from writes, provider acceptance separately
from recipient delivery, and current background-job state separately from older
import samples. Optional extensions and suggested priority are not approved new
scope. Follow upstream issue routing for dependency defects.

## Validation

For documentation-only changes, inspect the diff, run `git diff --check` and
verify local Markdown targets/anchors in the changed documents. Application
tests and asset builds are unnecessary when runtime files are unchanged.

## Follow-ups

Use `docs/PROGRESS.md` for the remaining work list. Update its reviewed baseline
and link dated feature evidence whenever implementation or acceptance changes.
