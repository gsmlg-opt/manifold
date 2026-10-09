# OAuth setup without a fixed public callback

Manifold supports Microsoft 365 and personal Outlook.com device-code login and
retains browser redirect login for Gmail and existing Microsoft configurations. Configure applications at
**Settings → OAuth** (`/settings/oauth`). These settings are intended for a
trusted local instance; they do not add administrator authentication.

## Microsoft: device code

Use this mode when the installation has no fixed public hostname, or the browser
runs on a different machine from Manifold. New Microsoft configurations select
**Device code** by default.

1. Register an application in Microsoft Entra with **Accounts in any organizational
   directory and personal Microsoft accounts** as the supported account type.
   Manifold uses the `common` authority for work/school and personal Outlook.com
   accounts. The application registration must allow the account type you use.
2. Under **Authentication → Advanced settings**, enable **Allow public client
   flows**. Device-code authorization needs no redirect URI or client secret.
3. Add delegated **User.Read**, **Mail.Read**, and **Mail.Send** permissions. Obtain
   administrator consent if the tenant requires it. Do not add **Mail.ReadWrite**.
4. In Manifold, select **Device code** and save the **Application (client) ID**.
5. Add or reconnect a Microsoft receive/send method. Start login, open the
   Microsoft verification website, and enter the displayed user code. The
   browser can be on another device. Manifold waits for approval and then binds
   the signed-in mailbox to the selected account.

`offline_access` enables background token refresh. Device codes expire; a denied,
canceled, or expired login needs a fresh start. Tenant policies can disallow this
flow even when the application is configured correctly.

Existing Microsoft configurations retain **Browser redirect** mode and their
encrypted secrets. Switching mode or changing the client ID disables affected
receive/send methods and requires reconnect. Switching to device code clears the
stored client secret. Switching back to browser redirect requires a new secret
and an exactly registered callback URI. Saving an unchanged configuration does
not interrupt connections.

## Gmail: browser redirect

Google's device-code flow permits only its documented limited set of scopes.
That set excludes `gmail.readonly` and `gmail.send`, so it cannot receive or send
Gmail messages for Manifold.

Create a **Web application** OAuth client, enable the Gmail API, configure the
consent screen, and fill in **Callback URL** in Settings OAuth. Register that
exact URL in the Google Cloud client, then save the callback, client ID, and
secret. Add test users for a testing-mode application, and complete
Google verification before public use when required.

New Google configurations default to this editable localhost callback:

```text
http://localhost:4290/connectors/gmail/callback
```

Manifold uses the saved URL unchanged in the authorization request, callback
comparison, and token exchange. You can set a different localhost port or path,
or an HTTPS URL.

For a local server that cannot receive the browser's localhost redirect:

1. Add, reconnect, or upgrade a Gmail method. Manifold opens its Google login page.
2. Select **Start Google login**, then **Open Google login**. Keep Manifold's page
   open while approving access in the new tab.
3. Google redirects to the registered localhost URL. Even if that page cannot be
   reached, copy its complete address from the browser's address bar.
4. Paste that address into **Final Google redirect URL** on Manifold's login page
   and select **Complete Google login**.

The pasted address must include the `code` and `state` from this login attempt.
Manifold parses it locally and completes the existing PKCE authorization; it does
not fetch the pasted URL. The URL is cleared after submission and filtered from
application request logs. Do not share it. A stale, denied, or expired attempt
requires starting again. Refreshing the login page also requires a fresh start.

No reachable localhost listener or callback forwarding is needed for this manual
completion. The existing automatic callback route remains available when the
browser can reach it. This remains Google's Web application authorization-code
flow, with an exactly registered redirect URL.

Existing Google configurations without a saved callback continue to use the
configured Phoenix Endpoint URL until a different callback is saved. Saving the
unchanged legacy form preserves its configuration and active connections. Changing
the callback requires reconnect, just like rotating credentials. API updates
that omit the callback preserve its current value.

The callback migration preserves existing credentials and generations. Clear
saved callback URLs before rolling back that migration.

## Storage and configuration changes

Client IDs, callback URLs, and login modes are public configuration. Browser-mode client secrets,
device codes, and user tokens are encrypted with the stable
`MANIFOLD_CONNECTOR_ENCRYPTION_KEY`. Do not rotate that key without a credential
migration. Device codes and tokens are never displayed in errors or activity
logs; only the provider's user code is shown during login.

Saving or removing provider settings takes effect without restarting the
application. In-progress login is bound to the provider-setting generation and
cannot complete after that configuration is changed or removed. Removing a
configuration is local and does not revoke the grant at the provider.

## Provider documentation

- [Microsoft device authorization grant](https://learn.microsoft.com/en-us/entra/identity-platform/v2-oauth2-device-code)
- [Microsoft public-client registration](https://learn.microsoft.com/en-us/entra/identity-platform/scenario-desktop-app-registration)
- [Google device-flow allowed scopes](https://developers.google.com/identity/protocols/oauth2/limited-input-device#allowedscopes)
- [Google installed-app authorization](https://developers.google.com/identity/protocols/oauth2/native-app)
