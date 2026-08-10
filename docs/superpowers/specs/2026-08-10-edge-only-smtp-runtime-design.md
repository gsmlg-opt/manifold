# Edge-only SMTP Runtime

## Decision

The main `manifold` runtime is a mail client and must not start an inbound SMTP
listener. Inbound SMTP remains available only in the separate `manifold_edge`
release.

Outbound SMTP account support is unchanged. `Manifold.Connectors.SMTP.Client`
continues to connect to user-configured SMTP submission servers and does not
depend on the inbound `manifold_smtp` application.

## Runtime composition

- Remove `manifold_smtp` from the main `manifold` release application list.
- Keep `manifold_smtp` in the `manifold_edge` release application list.
- Disable the `manifold_smtp` listener by default so the development umbrella
  can start without opening an SMTP port.
- Enable the listener explicitly when `MANIFOLD_ROLE=edge` selects the edge
  runtime configuration.
- Do not add a main-runtime SMTP enable switch. Local inbound SMTP is outside
  the main mail-client runtime boundary.

The SMTP application may still be compiled in the umbrella because the edge
release and focused tests use it. In a normal development boot it may start an
empty supervisor, but it must not start admission processes, acceptors, or a TCP
listener.

## Development workflow

`mix manifold.run` and the managed devenv process start the Phoenix mail client,
API, database-backed workers, and connector processes. They no longer advertise
or open the development SMTP port `2525`.

Documentation must distinguish the outbound SMTP client from the edge-only
inbound SMTP server.

## Verification

Focused checks must prove:

1. The main release application list excludes `manifold_smtp`.
2. The edge release application list includes `manifold_smtp`.
3. Default development configuration disables the SMTP listener.
4. Edge runtime configuration enables the SMTP listener.
5. Starting the normal devenv runtime leaves port `2525` closed while web and
   API endpoints remain ready.
6. Existing `manifold_smtp` and SMTP connector tests continue to pass.

## Documentation and compatibility

Update the README, development task description, and repository development
skill reference to describe the edge-only listener boundary. No database,
migration, credential, or external API changes are required.
