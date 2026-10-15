# EAS ActiveSync client (Exmail / on-prem)

## Scope

Read-only Exchange ActiveSync connector: Provision → FolderSync → Sync →
ItemOperations, with Basic Auth over HTTPS.

## Ownership

| Area | Module |
| --- | --- |
| HTTP/WBXML client | `Manifold.Connectors.EAS.Client` |
| HTTP policy / TLS selection | `Manifold.Connectors.EAS.HTTPAdapter` |
| Native HTTP execution | `Manifold.Core.HTTPClient` → `HTTP.fetch` |
| WBXML codec | `Manifold.Connectors.EAS.WBXML` |
| Transport behaviour | `Manifold.Connectors.EAS.Transport` |
| Provider adapter | `Manifold.Connectors.Provider.EAS` |
| Discover / test / create | `Manifold.Connectors` (`test_eas_connection`, `create_eas_account`) |
| Settings schema | `Manifold.Connectors.Schema.EasSettings` |

## HTTP transport

Published 0.21.10 includes
[PR #124](https://github.com/gsmlg-dev/http_fetch/pull/124), resolving
[http_fetch#121](https://github.com/gsmlg-dev/http_fetch/issues/121). The native
HTTP/1 parser rejects a textual `HTTP/2.0 200 OK` response. The native migration
is accepted for the v0.6.4 release candidate: the full affected regression passes, including
four actual-TLS rejection gates for OTP/ex_ssl × HTTP/0.9/HTTP/2.0. No local
HTTP parser workaround is used.
Native parsing also handles valid 100/103 interim responses and rejects 101;
the former custom parser rejected all informational responses.


Locked `http_fetch` and `ex_ssl` are both 0.21.10. `HTTPAdapter` keeps EAS policy
and calls the shared native client; Fetch owns framing and cancellation, with
no private EAS response parser. OTP TLS remains the default; explicit account
configuration may select ex_ssl. Requests use fresh HTTP/1 connections, HTTPS
peer verification, raw WBXML, and no redirects or transport retries. Publication
is tracked separately from local release-candidate acceptance.

Timeouts accept finite non-negative milliseconds (`0` supported, `:infinity`
rejected). Defaults are 15 seconds for connect and 60 seconds for the complete
request, including connect, response headers and every body fragment. Bodies
are capped at 64 MiB; combined initial response headers and trailers at 64 KiB
and 200 fields. Native framing additionally caps chunk-size lines at 8 KiB and
trailers at 64 KiB/128 fields. Trailer headers remain separate response metadata.

The published 0.21.10 full affected consumer gate passed on 2026-10-15:
910 tests, zero failures or exclusions, seed 42 (41 core, 664 connectors,
179 outbound, 13 cloud and 13 OAuth). Strict development and test compilation
also passed. Credentialed provider staging is outside this local evidence.

The earlier 2026-10-15 0.21.8 focused consumer gate passed 41 shared-client tests and 102
DAV/EAS tests with seed 42 and no failures, including controlled TLS/WBXML,
framing, deadline and DAV migration fixtures. The subsequent 0.21.8 full affected
run reported 907 tests, 906 passes and one failure in #121; this dated failure
is preserved as history, separately from the passing published 0.21.10 rerun.

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
