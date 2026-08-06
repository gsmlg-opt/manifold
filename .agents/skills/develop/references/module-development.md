# Module Development Notes

## Boundary and ownership

- `apps/manifold_data`: database schema, migrations, repository, Oban configuration.
- `apps/manifold_accounts`: account/domain/mailbox core ownership and validation.
- `apps/manifold_mail`: MIME projection and folder/thread/message modeling.
- `apps/manifold_connectors`: external provider sync adapters and provider state models.
- `apps/manifold_smtp`: inbound SMTP ingestion and durability boundaries.
- `apps/manifold_outbound`: outbound queueing and provider request workflows.
- `apps/manifold_storage`: raw data and attachment persistence.
- `apps/manifold_web`: LiveView/UI surfaces and admin workflows.
- `apps/manifold_api`: HTTP API layer.
- `apps/manifold_edge`: edge-only release behavior.
- `apps/manifold_core`, `manifold_security`, `manifold_cloud`: shared foundations.

## Development approach

- Keep logic inside the owning app boundary; do not push module coupling into callers.
- Place data model and contract changes in `manifold_data` migrations first.
- Implement behavior in the owning app module (context/handler), then wire UI/API callers.
- Update tests in the corresponding `apps/*/test` subtree for any behavior change.

## Module feature checklist

1. What does this feature change in state/contract?
2. Which boundary owns this change?
3. Does it require migration, new job, or external config?
4. What tests prove the change and regression behavior?
5. What operational side effects are visible (jobs, logs, endpoints, security)?

## Commands to verify module changes

- `mix test apps/<app>/test`
- `mix test` (full suite only when the touched module set is narrow and you want extra confidence)
- `mix format --check-formatted`
- `mix compile --warnings-as-errors`
