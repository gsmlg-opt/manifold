# Development progress and remaining work

## Snapshot and evidence

- Reviewed: **2026-10-13**.
- Local source baseline: **v0.6.2**, `cacc2e5` on `main`.
- Milestones **0–6 are implemented** within their original scopes. Later work
  added account-selected sending, IMAP/EAS, Contacts/Calendar and iCloud writes.
- This snapshot checks documentation against source and existing acceptance
  records. It does not rerun tests, verify remote publication, or inspect current
  provider accounts, background jobs or mailbox backfill completion.

HTTP-client migration checkpoint: **2026-10-15**, based on `1d150fc` in
`codex/http-fetch-client`, accepted for the v0.6.4 release candidate; see [HTTP clients](HTTP_CLIENT.md) for its scope and evidence.

Calendar correction checkpoint: **2026-10-19**, `codex/calendar-local-first` based
on `5a6825f`. Independent local calendars and simultaneous Google/iCloud bindings
supersede the Account-owned Calendar model below. See the [current guide](CALENDARS.md)
and [scoped implementation evidence](superpowers/implementation/calendar-validation.md).
This checkpoint does not re-audit unrelated areas or claim deployment.

HTTP-server migration checkpoint: **2026-10-22**, isolated
`codex/gaoxy-http-server` candidate based on v0.6.8. Published Gaoxy 0.9.0 fixes
the message-capacity and active-drain defects; Web/API and Edge integration has
**257 scoped tests passing**, and both production releases are assembled.
Packaged startup and actual local HTTP smoke pass; see the
[migration record](../.agents/skills/develop/references/http-server-migration.md).
No merge or deployment has occurred.

Use [the documentation index](README.md) for current setup and architecture.
Historical plan checkboxes and test totals are not a project-wide completion
percentage. **Implemented** describes code; **verified** requires evidence for
the specific behavior, revision and environment being claimed.

## Implemented capabilities

| Area | Current implementation | Evidence and limits |
| --- | --- | --- |
| Business HTTP clients | Shared native Fetch 0.21.10 for Gmail/Graph/OAuth, outbound Gmail/Graph/Resend, Cloud, DAV and EAS | [Migration and acceptance](HTTP_CLIENT.md): 910 affected tests passed; upstream #114/#115/#121 fixed and verified. Accepted for v0.6.4 integration into main; credentialed provider staging and runtime switching remain separate. |
| HTTP servers | Isolated Gaoxy 0.9.0 migration for Web/API Endpoints and Edge; all direct Bandit dependencies removed | [Migration record](../.agents/skills/develop/references/http-server-migration.md): 257 scoped tests pass, including large composer messages and active Edge shutdown; both packaged releases serve actual HTTP with no Bandit/ThousandIsland. No merge or deployment. |
| Foundation and inbound (M0–1) | Umbrella, PostgreSQL/Oban, recipient resolution, durable spool, atomic acceptance, archival and recovery | [Original plan](IMPLEMENTATION_PLAN.md), [crash boundaries](CRASH_BOUNDARIES.md); current SMTP listener runs in the optional edge release |
| Mailbox (M2) | MIME projection, safe HTML display, inbound attachments, threading, search, folders and read/star/archive/trash actions | [M2](MILESTONE_2_PLAN.md); Gmail/Graph read changes remain local |
| Outbound (M3 and later extensions) | Plain-text drafts, reply/forward, frozen queue payloads, Gmail API/Graph/SMTP submission, legacy Resend webhooks and uncertain-submission handling | [Current send contract](DESIGN.md#225-account-selected-outbound-methods); HTML composition and outbound attachments are pending extensions |
| Security (M4) | Versioned assessment, quarantine, policy/retry framework and SMTP abuse limits | [M4](MILESTONE_4_PLAN.md); default authentication, malware and spam adapters return `not_evaluated` |
| Cloud ingress (M5) | Separate edge release, recipient snapshots, signed pull, streamed durable import and idempotent acknowledgement | [M5](MILESTONE_5_PLAN.md) |
| Connectors (M6 and later extensions) | Gmail/Graph polling, IMAP/EAS Inbox receive, encrypted credentials, durable provider identities/cursors, Google pasted-redirect completion and Microsoft device login | [OAuth setup](OAUTH_SETUP.md), [feature index](superpowers/README.md); Gmail/Graph receive remains read-only |
| Sync admission | Gmail pacing/cooldown and Microsoft shared receive/send admission | [Gmail record](../.agents/skills/develop/references/gmail-sync-rate-limiting.md), [Microsoft record](../.agents/skills/develop/references/microsoft-sync-throttling.md); limits coordinate within one VM |
| Account lifecycle | Disable and asynchronous local deletion with lifecycle fencing and retained shared-data safety | [Account actions](../.agents/skills/develop/references/account-actions.md); provider-side deletion/revocation is separate scope |
| Contacts | Account-owned local CRUD, iCloud conditional bidirectional resource sync, explicit destinations and offline saves | [Current guide](ICLOUD.md), [historical acceptance](ICLOUD_ACCEPTANCE.md) |
| Calendar | Independent local CRUD, bounded recurrence/timezones, simultaneous Google/iCloud targets, independent revisions/conflicts/unknown attempts, persisted enrollment and live workspace | [Current guide](CALENDARS.md), [implementation evidence](superpowers/implementation/calendar-validation.md); real-provider joint acceptance NOT RUN |
| Interfaces | Phoenix webmail, separate REST/GraphQL read/search API, settings, job/delivery views and build-version badge | [API guide](../apps/manifold_api/README.md), [build badge](../.agents/skills/develop/references/appbar-version.md); web/API access is trusted at the deployment boundary |

## Remaining verification

These implemented flows still need the following acceptance evidence. The
suggested order is advisory.

| ID | Suggested order | Task / owner | Completion evidence |
| --- | --- | --- | --- |
| V1 | First | Credentialed Apple writes — Connectors, Contacts, Calendars, Web | On an authorized disposable account, verify contact/event create/edit/delete, conditional conflicts, lost-response reconciliation and recovery. Real Apple discovery/read imported 132 contacts and 79 events in the [recorded repair](ICLOUD_ACCEPTANCE.md#configured-account-error-repairs--2026-10-11); that run issued zero writes. [Credentialed writes remain NOT RUN](../.agents/skills/develop/references/icloud-contacts-calendars.md#constraints-and-follow-ups). |
| V4 | Before Calendar rollout | Joint Google/iCloud acceptance — Calendars, Connectors, Web | Use authorized disposable calendars to verify Calendar authorization, simultaneous CRUD, reconnection, exceptions and uncertain outcomes. Localhost HTTP and migration probes are recorded separately in [Calendar evidence](superpowers/implementation/calendar-validation.md); real-provider reads/writes for the new path are NOT RUN. |
| V2 | First | Microsoft work/school and outbound staging — Connectors, Outbound, Web | Exercise work/school device login, receive/send grants, actual sending, authoritative Sent import, credential rotation and reconnect. [Personal Outlook login and 258 received messages were verified](../.agents/skills/develop/references/microsoft-device-oauth.md#personal-account-and-verification-url-repair-2026-10-09); work/school authorization and credentialed sending were not exercised. Use the current device flow instead of historical callback-only instructions. |
| V3 | First | Gmail/SMTP lifecycle and backfill evidence — Connectors, Outbound, Web | Complete the [staging checklist](../.agents/skills/develop/references/gmail-receive-send-methods.md#staging-smoke-checklist) with the [current OAuth flow](OAUTH_SETUP.md), including real sending, reconnect and no blind resend after an uncertain outcome. Inspect current cursors/jobs before claiming Gmail or IMAP backfill completion; historical import samples do not establish today's state. Controlled tests cover cooldown; the [Gmail sample](../.agents/skills/develop/references/gmail-sync-rate-limiting.md#validation) did not trigger a real long cooldown. |
| V5 | Before Gaoxy rollout | Target reverse-proxy/TLS acceptance — Web, API, Edge, operators | Local implementation and packaged startup pass on Gaoxy 0.9.0. Verify Caddy WebSocket/longpoll forwarding, TLS and production timeout/body limits on the authorized target; target deployment remains NOT RUN. [Consumer evidence and finite limits](../.agents/skills/develop/references/http-server-migration.md). |

## Engineering follow-ups

These tasks are recorded implementation debt or pending integrations. They are
separate from the completed original milestone checklists.

| ID | Suggested order | Task / owner | Completion criterion and source |
| --- | --- | --- | --- |
| E1 | Next | Avoid repeated historical `received_at` repair — Connectors, Mail | Replace the per-page scan/write repair with bounded incremental or explicit repair work; preserve timestamp semantics and restart safety. Measure database work on a large imported mailbox. [Recorded debt](../.agents/skills/develop/references/microsoft-sync-throttling.md#follow-up), [current sync source](../apps/manifold_connectors/lib/manifold/connectors/sync.ex). |
| E2 | Next | Isolate slow connector work — Connectors, Data/config | Prevent slow IMAP pages from occupying all capacity needed by Gmail/Graph continuations; demonstrate bounded cross-provider progress under queue pressure. [The shared connectors queue has two slots](../config/config.exs); [queue isolation is a recorded follow-up](../.agents/skills/develop/references/microsoft-sync-throttling.md#follow-up). |
| I1 | Before public inbound deployment | Integrate production authentication/scanning — Security, Ingest, Edge | Configure and verify real DNS-backed SPF/DKIM/DMARC and chosen malware/spam services, including unavailable-engine policy and quarantine. [M4](MILESTONE_4_PLAN.md) completed adapter contracts; [default adapters](../apps/manifold_security/lib/manifold/security/adapters.ex) do not evaluate messages. |
| I2 | When object storage is needed | ESS/S3-compatible raw/blob adapters — Storage, Ingest | Implement the existing behavior contracts and verify object-store outage/recovery while the spool has capacity. Current adapters are local filesystem only. [Storage plan](DESIGN.md#133-storage-adapters). |
| I3 | Before production rollout | Operational health and backup/restore acceptance — API, Data, Storage, Edge, operators | Verify dependency/queue/spool health and a restore of database, raw mail, blobs, encryption key/configuration and unarchived spool. [Design health requirements](DESIGN.md#193-operational-health), [backup requirements](DESIGN.md#204-backup-and-recovery); the [API health response](../apps/manifold_api/lib/manifold_api/json.ex) currently returns a static service status. A complete deployment acceptance record is still needed. |
| D2 | After upstream fix is available | Icon-button accessibility dependency — Web | Verify an updated dependency forwards accessible names, then review the temporary slotted text with keyboard/screen-reader checks. [Upstream duskmoon-elements#86 and current compensation](../.agents/skills/develop/references/contacts-calendar-workspace.md#upstream-accessibility-follow-up). The compensation permits current use. |

For multiple Graph-calling VMs, shared admission enforcement needs a separate
design before claiming a deployment-wide concurrency limit. Gmail likewise does
not promise distributed or cross-restart quota accounting. This is conditional
deployment work, not a requirement of the current single-VM limiter.

## Optional next product scope

These features are not implemented and require scope/design decisions before
being scheduled. They are not incomplete steps in Milestones 0–6.

| Area | Candidate extensions | Source |
| --- | --- | --- |
| Writing mail | Outbound attachments, HTML/rich-text composition, Gmail/SMTP sender aliases | [Send follow-ups](../.agents/skills/develop/references/gmail-receive-send-methods.md#follow-ups) |
| Mailbox interactions | Gmail/Graph read-state write-back, Shift range selection, configurable auto-mark delay | [Read/unread follow-ups](../.agents/skills/develop/references/mailbox-read-unread-controls.md#follow-ups) |
| Sync latency | Gmail watch and Graph subscriptions, retaining durable polling fallback | [Send/connector follow-ups](../.agents/skills/develop/references/gmail-receive-send-methods.md#follow-ups) |
| Calendar | Future-series splits, invitations and RSVP | [Supported calendar boundary](CALENDARS.md#using-the-workspace) |
| Contacts/Calendar providers | Google Contacts synchronization; remote address-book/calendar container management | [Contacts scope](ICLOUD.md), [Calendar scope](CALENDARS.md) |
| Additional protocols | POP3/EWS (current placeholders), JMAP, EAS Autodiscover | [Receive kinds](../apps/manifold_connectors/lib/manifold/connectors/schema/receive_method.ex), [EAS follow-ups](../.agents/skills/develop/references/eas-activesync-client.md#follow-ups) |

Direct recipient-MX delivery remains an architectural non-goal; it is not a
pending task. Provider-side account deletion/revocation and an edge purge
protocol require separate lifecycle designs.

## Update rules

1. Update the snapshot date/revision when reviewing status. Distinguish local
   source version from independently verified publication and runtime state.
2. Keep implemented behavior, acceptance gaps, engineering debt and optional
   product scope separate. Move a task only when its completion evidence exists.
3. Add dated evidence in the owning acceptance/feature record and link it here;
   preserve prior FAIL/BLOCKED/NOT RUN checkpoints with their original context.
4. Update the matching [develop reference](../.agents/skills/develop/SKILL.md).
   Historical plans remain execution records; do not infer or bulk-check their
   individual steps from the existence of a completed feature.
