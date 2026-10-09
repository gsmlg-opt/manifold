# iCloud Contacts and Calendars Implementation Plan

> **For agentic workers:** Use subagent-driven-development or executing-plans to implement these scoped tasks. Workers share the feature worktree; do not revert others' edits.

**Goal:** Ship local contact management, automatic read-only iCloud contacts/calendar synchronization, and one verified release.

**Architecture:** Shared schemas/migrations live in manifold_data; contacts and calendars have independent query contexts. Independent iCloud connections, secure DAV discovery/transport/parsing, and Oban synchronization live in manifold_connectors. LiveViews expose contacts, calendars and iCloud settings without mailbox coupling.

**Tech Stack:** Elixir/OTP, Ecto/PostgreSQL, Oban, Req, Saxy, Phoenix LiveView and DuskMoon.

## Shared contracts

- `Manifold.Data.Schema.ICloudConnection`: apple_id, password_ciphertext, enabled, contacts_enabled, calendars_enabled, generation, per-service status/error/synced_at, next_sync_at. IDs use Ecto UUIDs. No mailbox/user foreign key.
- `Manifold.Data.Schema.DAVCollection`: connection_id, kind (`contacts`/`calendars`), href, name, sync_token. Unique connection/kind/href.
- `Manifold.Data.Schema.Contact`: collection_id (nil for local), resource_href, uid, etag, raw, full_name, given_name, family_name, organization, notes; emails/phones/addresses are lists of maps. Unique collection/resource_href for imports.
- `Manifold.Data.Schema.CalendarEvent`: collection_id, resource_href, uid, recurrence_id (empty for master), etag, raw, summary, description, location, starts_at, ends_at, timezone, all_day, recurrence_rules, excluded_dates. Unique collection/resource_href/uid/recurrence_id.
- `Manifold.Contacts`: list_contacts(opts), get_contact(id), create_contact(attrs), update_contact(id, attrs), delete_contact(id), change_contact(contact, attrs). Imported updates/deletes return `{:error, :read_only}`.
- `Manifold.Calendars`: list_calendars(), list_events(collection_id, opts), get_event(id).
- `Manifold.Connectors.DAV.VCard.parse(binary)` returns `{:ok, contact_attrs}` or sanitized `{:error, reason}`; `ICalendar.parse(binary)` returns `{:ok, [event_attrs]}`. Parser modules do not query DB.
- DAV multistatus parser returns namespace-qualified property values, hrefs, response/propstat status and optional sync token, preserving names as strings.
- Connection context and synchronization expose only sanitized public fields; decrypt only inside DAV operations. Jobs carry UUID/generation only.

## Task 1: isolated reproducible baseline

Files: connectors mix.exs and necessary mix.lock entries, approved design/reference, this plan.

- [x] Create `.trees/icloud-contacts-calendars` on `codex/icloud-contacts-calendars`; leave original uncommitted changes intact.
- [x] Replace unavailable historical ex_ssl Git revision with the already consumer-validated exact Hex 0.17.1 dependency; fetch clean dependencies and record provenance. Do not copy unrelated dependency/UI maintenance into this branch.
- [x] Run `devenv shell -- bash -c 'cd .trees/icloud-contacts-calendars && mix test apps/manifold_connectors/test/manifold/connectors/crypto_test.exs'`. Expected: existing crypto gate passes on isolated source.

## Task 2: schemas and independent domain contexts (worker A)

Files: new data schemas under `apps/manifold_data/lib/manifold/data/schema/`; migration `20261010000100_add_icloud_contacts_calendars.exs`; new `apps/manifold_contacts/{mix.exs,lib,test}` and `apps/manifold_calendars/{mix.exs,lib,test}`.

- [x] Add FK/unique/check constraints and raw/projection fields from contracts. Database FK cascades isolate imported data per connection; local contacts have no connection.
- [x] Write CRUD/read-only/search tests first, including malformed IDs, repeated email addresses across independent sources, postal/multiple-value preservation, and deterministic list ordering.
- [x] Implement context validation/query operations using Ecto changesets and bounded pagination.
- [x] Test calendar list/event details and recurrence exception identity without pretending to expand occurrences.
- [x] Run focused context tests; parent coordinates migrations and build environment to avoid racing Mix tasks.

Example acceptance:
```elixir
assert {:ok, contact} = Manifold.Contacts.create_contact(%{full_name: "Ada", emails: [%{"value" => "ada@example.test"}]})
assert Enum.any?(Manifold.Contacts.list_contacts(search: "Ada"), &(&1.id == contact.id))
assert {:ok, _} = Manifold.Contacts.update_contact(contact.id, %{full_name: "Ada Lovelace"})
assert {:ok, _} = Manifold.Contacts.delete_contact(contact.id)
```

## Task 3: bounded DAV/vCard/iCalendar parsers (worker B)

Files: `apps/manifold_connectors/lib/manifold/connectors/dav/{xml,v_card,i_calendar}.ex` and focused tests/fixtures.

- [x] Add failing namespace/property/status/DTD/truncation/multistatus tests.
- [x] Add vCard tests for UTF-8 folding, escapes, quoted parameters, multiple emails/phones/addresses, groups, raw retention, bounded input and invalid cards.
- [x] Add iCalendar tests for all-day, UTC/floating/TZID dates, multiple VEVENTs, recurrence rules/exceptions and escaped descriptions; reject malformed/incomplete syntax.
- [x] Implement safe namespace-aware Saxy parsing with finite limits, no atom creation or entity/DTD loading.
- [x] Run `mix test apps/manifold_connectors/test/manifold/connectors/dav` after dependency setup.

## Task 4: secure DAV transport, discovery and synchronization (parent)

Files: new DAV client/URL modules; `icloud.ex`, `icloud/sync.ex`; jobs `poll_icloud.ex` and `sync_icloud.ex`; connectors mix.exs; config/config.exs; focused connector tests.

- [x] Implement Apple HTTPS host/port validation for every bootstrap/href/redirect before credential dispatch. Disable automatic redirect/retry, cap response bytes/deadlines, and retain sanitized failures only.
- [x] PROPFIND principal, home sets and collections; REPORT sync-token deltas when supported, otherwise ETag listings plus changed GET/multiget; bounded complete results only.
- [x] Encrypt app passwords with connection UUID AAD; connect queues initial sync; credential replacement/disable/disconnect increments generation and invalidates old jobs.
- [x] Commit one complete service snapshot/checkpoint under generation lock; no network inside DB transaction. Reject incomplete reads before deletion; contacts/calendar failures remain independent.
- [x] Add unique per-connection jobs and five-minute polling; honor Retry-After and sanitize status errors.
- [x] Prove idempotence, additions/updates/deletes, failure retention, credential secrecy, lifecycle races and unique jobs with fixtures; verify actual HTTP dispatch/redirect/limits with local controlled servers.

## Task 5: UI and application wiring (worker after contracts stabilize)

Files: web live/contact_live/index.ex, calendar_live/index.ex, settings_live/icloud.ex; router, app/settings layouts, settings components/path hook, web mix.exs; scoped LiveView tests; root mix.exs release apps.

- [x] Add source-labelled contacts list/search/details and local CRUD, imported read-only records.
- [x] Add calendar selection/events/detail with explicit timezone/recurrence metadata.
- [x] Add secure iCloud form/help, independent service toggles, manual sync, disable/reconnect/disconnect and per-service outcomes. Clear app password after submit; never assign decrypted connection to view.
- [x] Wire navigation/new contexts/main release and secret parameter filtering.
- [x] Run focused LiveView/navigation gates and build assets. Browser-check both existing themes, empty/error/detail states and settings flow.

## Task 6: acceptance, documentation and one release

Files: README, product design, feature reference, scoped evidence/report; release workflow only if evidence proves a necessary scoped correction.

- [x] Review the final diff against every approved spec requirement; preserve unrelated work and stop on unrelated failing tests.
- [x] Run focused contact/calendar/DAV/connection/LiveView/TLS gates, changed-file formatting, strict compilation, asset build and controlled actual-wire gates.
- [x] Record actual iCloud credentialed verification separately; never substitute fixtures for actual Apple traffic or put passwords in chat/docs.
- [x] Record migrations/startup/rollback guidance, precise test results and limitations; update feature reference to implementation state.
- [x] Commit scoped feature, push, integrate the reviewed branch without absorbing original dirty work, and dispatch existing release workflow once for the next available minor version (initial target v0.4.0).
- [ ] Verify workflow success, tag/source identity, both release archives/checksums, migration/startup behavior and Docker images. Fetch/synchronize safely; stop after reporting the one release.

### Release checkpoint

v0.4.0 workflow/publication completed; actual relocated main archive web startup
failed due to build-path asset configuration. Public release is marked
prerelease; tag/artifacts retained. Supported runtime override correction is
implemented and passes relocated local startup. Final publication verification
continues under the user-authorized v0.5.0 correction release. Preserve public
v0.4.0 history and stop after verified v0.5.0 publication.
