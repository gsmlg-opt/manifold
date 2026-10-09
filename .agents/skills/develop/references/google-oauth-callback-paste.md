# Google OAuth completion by pasted redirect URL

- **Date:** 2026-10-07
- **Scope:** Gmail receive/send, reconnect and upgrade login on local servers
  whose browser cannot reach the registered localhost callback.
- **Operator guide:** `docs/OAUTH_SETUP.md`.

## Ownership and behavior

`SettingsLive.GoogleLogin` owns `/settings/accounts/:id/google/login`, with
`purpose=receive|send`. Account method creation, reconnect and access upgrade
links open this page. GET validates the active account and provider configuration
without starting authorization. An explicit Start action creates the normal
OAuth transaction; Google opens in a new tab while the Manifold page remains.
The user pastes the full final redirect URL including `code` and `state`, even
when the browser reports the localhost page unreachable.

`OAuth.consume_callback_url/5` owns local parsing and one-time consumption. It
binds the URL to the page's active attempt, account, purpose, registered callback,
expiry and settings generation. It rejects ambiguous query parameters and never
fetches user-supplied URLs. The optional Google issuer response parameter is
accepted only as a single `iss=https://accounts.google.com`; a wrong or duplicate
issuer is rejected without consuming the authorization attempt. Callbacks without
`iss` remain supported. Consumption reuses the transaction's encrypted PKCE
verifier and `Connectors.complete_authorization/3` preserves identity, address,
scope, lifecycle and encrypted token-storage contracts.

Token exchange runs asynchronously. Double submission is ignored while pending;
rejected input is removed from browser markup, never retained in socket assigns,
and filtered from Phoenix logs via `callback_response_url`. Generic errors do not
include pasted URLs, codes, state, tokens or provider errors. A reload loses the
page's active attempt and requires a fresh start.

Async completion failures record a safe reason code in the server log while the
browser retains a generic completion error. Logging excludes pasted callback URLs,
authorization codes, state and sensitive provider error descriptions. Before this
logging was added, the exact reason for a historical failed completion could not
be recovered from the generic browser message or consumed transaction alone.

The existing automatic `/connectors/gmail/start` and callback routes remain usable.
Microsoft device login is unchanged. This is Google's web-client authorization
code flow with PKCE, not Google device authorization. No extra listener,
public hostname or forwarding is required for pasted completion.

## Verification

Scoped tests cover real Gmail token/identity adapters through mocked HTTP, both
receive and send, PKCE continuity, replay/expiry/configuration changes, invalid
callbacks and attempts, inactive accounts, and log redaction. Credentialed Google
authorization is operator verification and is not implied by mocked tests.

**Verified 2026-10-07:** OAuth transaction tests 31 and scoped Web tests 86 passed
with zero failures. Formatting and strict development compilation passed.

**Regression 2026-10-09:** Google redirect URLs can include the `iss` response
parameter. The receive/send LiveView completion fixtures now include Google's
issuer, and OAuth regression coverage checks correct, absent, wrong and duplicate
issuers. Adding a valid issuer first reproduced `oauth_state_mismatch` before the
fix. After the fix, the scoped OAuth transaction tests (31) and Google login
LiveView tests (7) passed with zero failures. Changed Elixir files passed formatting
checks and strict development compilation passed. Live Google authorization still
requires operator verification.

**Diagnostics regression 2026-10-09:** A mocked token exchange returning
`invalid_grant` first reproduced an empty completion failure log. After the fix,
all 8 scoped Google login LiveView tests passed, including safe reason logging,
callback/provider secret redaction and the generic completion failure UI.
Formatting and strict development compilation passed. The generic message no
longer implies every completion failure was caused by an account email mismatch.
