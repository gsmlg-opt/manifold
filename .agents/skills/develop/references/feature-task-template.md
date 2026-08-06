# Feature/Task Update Template

Copy this into `.agents/skills/develop/references/{name}.md` and fill every section.

## Feature

- **Name**:
- **Date**:
- **Owner/Requestor**:
- **Status**: `in-progress` / `done` / `blocked`

## Scope

- **Apps touched**:
- **Files changed**:
- **Reason for change**:

## Module ownership

- `manifold_data`:
- `manifold_accounts`:
- `manifold_connectors`:
- `manifold_web`:
- `manifold_api`:
- `manifold_smtp`:
- `manifold_outbound`:
- `manifold_ingest`:
- `manifold_storage`:
- `manifold_cloud`:
- `manifold_edge`:
- `manifold_core`:
- `manifold_security`:

## Design and data impact

- **Database/migration impact**:
- **API or background-job impact**:
- **Config / env impact**:
- **Security / auth / trust-boundary impact**:

## Implementation notes

- **What changed**:
- **Why this approach**:
- **Alternatives considered**:
- **Rollback notes**:

## Validation

- `mix test apps/<app>/test`
- `mix format --check-formatted`
- `mix compile --warnings-as-errors`
- `mix duskmoon_bundler.js.check` (if JS touched)
- **Result summary**:

## Post-task

- **Follow-ups**:
- **Opened issues / TODOs**:
- **Docs updated**:
