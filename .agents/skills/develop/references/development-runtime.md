# Development runtime

- Ownership: `devenv.nix` starts PostgreSQL and Manifold; `config/dev.exs`
  sets the development Logger level to `:info`.
- Devenv's native process manager writes logs beneath `DEVENV_RUNTIME`, which
  normally resides on `/run/user/<uid>` tmpfs. Successful SQL debug logging can
  fill this filesystem during sustained ingestion. Keep the default at `:info`;
  enable debug logging only for bounded investigations.
- If startup reports `No space left on device`, check the runtime filesystem
  and process log sizes. Archive logs to disk before truncating them. Preserve
  database state and stop any confirmed orphaned project processes before
  starting a replacement manager.
- `devenv processes down` fails when no manager is running, so an `&&` chain
  skips the subsequent startup. Check manager status and start directly when
  it is already stopped.
- Validate recovery with `devenv processes list`, PostgreSQL readiness and HTTP
  responses on ports 4290 and 4292. Verify that log growth remains bounded under
  ordinary activity; the Logger level reduces volume but does not rotate logs.
