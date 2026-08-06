# Task Development Notes

## Before starting

- Read the request, related ADR/issue context, and impacted apps.
- Identify a single success criterion and a file list.
- Check current working state (`git status`) for conflicts before edits.

## Task plan template

1. Scope: module(s), files, and behavior change.
2. Tests: target tests first, then broader checks.
3. Implementation: minimal patch, no unrelated refactors.
4. Validation: run scoped commands and collect output.
5. Post-task: note follow-up debt, migration notes, and docs touched.

## Scope-friendly test commands

- `mix test apps/<app>/test` for app-local verification
- `mix test` for repository-wide verification after coordinated feature work
- `mix format --check-formatted` before handoff
- `mix assets.build` if frontend files changed
- `mix duskmoon_bundler.js.check` if JS assets changed

## Task update rule

After each feature create or update, record the task outcome in a dedicated file
under `.agents/skills/develop/references/{name}.md`, where `{name}` is the feature or
task identifier.
