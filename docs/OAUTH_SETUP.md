# OAuth setup without a fixed public callback

Manifold supports Microsoft 365 device-code login and retains browser redirect
login for Gmail and existing Microsoft configurations. Configure applications at
**Settings → OAuth** (`/settings/oauth`). These settings are intended for a
trusted local instance; they do not add administrator authentication.

## Microsoft 365: device code

Use this mode when the installation has no fixed public hostname, or the browser
runs on a different machine from Manifold. New Microsoft configurations select
**Device code** by default.

1. Register an application in Microsoft Entra for accounts in any organizational
   directory. Manifold continues to support work/school accounts only.
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
consent screen, and register the exact callback shown in Settings. Save its
client ID and secret. Add test users for a testing-mode application, and complete
Google verification before public use when required.

For browser redirect login, the callback comes from the configured Phoenix
Endpoint URL, not the browser's current hostname. The development callback is:

```text
http://localhost:4290/connectors/gmail/callback
```

This needs no public domain when the browser and Manifold run on the same
machine. A browser on another device interprets `localhost` as that device, so
this callback will not reach Manifold. Remote browser login needs a reachable,
exactly registered callback. Google Desktop-client loopback authorization is a
different flow and is not implemented by Manifold's current web-client login.

## Storage and configuration changes

Client IDs and login modes are public configuration. Browser-mode client secrets,
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
