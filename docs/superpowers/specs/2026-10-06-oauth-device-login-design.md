# Microsoft device-code login and OAuth setup guidance

## Scope and behavior

Microsoft 365 work/school accounts gain public-client device authorization.
New Microsoft Settings forms default to device code: client ID only, no callback
or client secret. Existing configurations remain authorization-code clients;
operators may switch explicitly. Gmail retains its current web-client flow
because Google's allowed device scopes exclude Gmail read and send.

## Ownership

`manifold_data` owns the provider-mode and device-transaction migrations.
`manifold_connectors` owns mode validation, provider configuration, encrypted
device transactions, provider request/poll transport, shared grant completion,
and public-client refresh. `manifold_web` owns the Settings selector, mode-aware
help, start-controller dispatch, and a dedicated asynchronous device-login page.
Operator instructions live in `docs/OAUTH_SETUP.md` and README; the feature index
records implementation and validation.

## Compatibility and lifecycle

Database defaults and existing rows remain `authorization_code`. Settings APIs
that omit the mode preserve their previous behavior. Only Microsoft supports
`device_code`; only that mode permits a missing secret. Switching to device code
clears the old secret. Switching back requires a new secret. A real mode/client
change increments the existing generation and requires affected methods to
reconnect; an unchanged save remains a no-op.

Device login displays the provider's verification URI and user code. Provider
calls run asynchronously and respect the poll interval and slowdown responses.
Transactions bind the account, requested receive/send scopes, expiration, and
provider-setting generation. Encrypted device codes stay server-side. Concurrent
polls, cancellation, expiry, and settings changes must not complete stale grants.
Successful tokens reuse existing identity/address matching, scope checks,
encrypted persistence, folder initialization, and first-sync scheduling.

## Verification and exclusions

Focused tests cover settings compatibility and generation fencing, Microsoft
device transport and secret-free refresh, transaction concurrency/termination,
receive/send completion, and Settings/help/device LiveView behavior. Strict
compilation and formatting are required. Real Microsoft tenant login remains
separate from local simulated-provider validation.

Personal Microsoft accounts, Google Desktop-client loopback implementation,
provider push notifications, and remote mailbox mutation are outside this change.
