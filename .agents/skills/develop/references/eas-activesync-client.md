# EAS ActiveSync client (Exmail / on-prem)

## Scope

Read-only Exchange ActiveSync connector: Provision → FolderSync → Sync →
ItemOperations, with Basic Auth over HTTPS.

## Ownership

| Area | Module |
| --- | --- |
| HTTP/WBXML client | `Manifold.Connectors.EAS.Client` |
| WBXML codec | `Manifold.Connectors.EAS.WBXML` |
| Transport behaviour | `Manifold.Connectors.EAS.Transport` |
| Provider adapter | `Manifold.Connectors.Provider.EAS` |
| Discover / test / create | `Manifold.Connectors` (`test_eas_connection`, `create_eas_account`) |
| Settings schema | `Manifold.Connectors.Schema.EasSettings` |

## Protocol notes (QQ Exmail)

1. **Default protocol is 14.0**. QQ documents ActiveSync 14.0 only.
2. **QQ Exmail EAS is mobile-oriented**. Their gateway returns HTML HTTP 400
   to many non-phone clients (same class of failure as Microsoft Connectivity
   Analyzer / third-party EWS tools). For Exmail mail import, prefer **IMAP**
   (`imap.exmail.qq.com:993`) with an app password.
3. DeviceId is 32 lowercase hex (MS-ASHTTP style), not a fake `Appl…` prefix.
4. Plain query uses `Cmd&User&DeviceId&DeviceType`; sticky query mode after
   first success; QQ skips Settings DeviceInformation after Provision.


## Optional Domain

`connector_eas_settings.domain` is optional. When set, Basic Auth uses
`DOMAIN\user`; the `User` query parameter remains the username only.

## Follow-ups

- Capture a successful iOS ActiveSync trace against Exmail if FolderSync HTML
  400 persists (Mac Mail Exchange may use EWS, not EAS).
- Consider Autodiscover for host/path when users only know their email.
