# Contacts and Calendar workspaces

- Scope: UI redesign inspired by iCloud Contacts and Google Calendar. Google is
  a visual reference; provider synchronization remains iCloud-only.
- Style: compact navigation, clear selection, monogram contact portraits, a
  calendar canvas and contextual editors. Use the existing DM Sans / Fraunces
  typography, DuskMoon semantic tokens, sunshine and moonlight themes.

## Ownership

- `manifold_web/live/contact_live/index.ex`: account filtering, alphabetical
  contact browser, detail and editor. Keep filters when navigating between
  list/detail/edit, and retain multi-value metadata, copy, synchronization
  preference, read-only and conflict controls.
- `manifold_web/live/calendar_live/index.ex`: selected calendar, date navigation,
  month and agenda views, calendar settings and event detail/editor.
- `manifold_web/live/calendar_live/display.ex`: wall-date presentation, month
  boundaries and exclusive end-date handling. This is not a recurrence engine.
- `manifold_calendars`: complete date-range queries for stored events; month
  rendering must not rely on the old first-50-event listing.
- `manifold_web/assets/css/{contacts,calendar}.css`: scoped workspace styles,
  imported by `app.css`. These workspaces fill the application content area
  instead of inheriting the generic settings-page width and padding.

## Behavioral constraints

All writes still commit locally before existing asynchronous iCloud dispatch.
Do not change provider credentials, jobs or DAV reconciliation from these views.
Recurring master records and exceptions are displayed as stored; occurrences are
not expanded. Keep source timezone semantics and use exclusive all-day ends.
Retain explicit destination adoption, copy and destructive-action confirmations.
Mutation redirects retain the selected month/view; a spanning event edited from
another month must not move the canvas back to its start month. Toggling an
event to all-day and back preserves its previous timezone when the disabled
input is absent from the browser payload.
Small screens must support list/detail navigation and a readable agenda without
horizontal page overflow. Controls must work with keyboard focus and respect
reduced motion. Account and event details must wrap long text.

## Validation

Run the Contacts and Calendar LiveView tests, Calendar display tests and owning
domain tests through root `devenv shell`. Use a disposable database for browser
fixtures; disable sync dispatch and avoid mutating real imported records.
Build assets and verify desktop/mobile layouts in both themes, search and source
selection, date/view navigation, editors and detail panels.

## Upstream accessibility follow-up

`@duskmoon-dev/el-button` 1.9.0 does not forward an icon-only button's host
`aria-label` to the native shadow button. See
`duskmoon-dev/duskmoon-elements#86` (Bug, internal request, needed).
Until fixed, Contacts remove-value controls and the mobile Calendar navigation
toggle supply slotted screen-reader text as well as their host labels.

## Acceptance — 2026-10-11

- 70 scoped tests passed: Contacts and Calendars domain suites, Contacts and
  Calendar LiveViews, Calendar display boundaries and application layout tests.
- `mix format --check-formatted`, strict compilation and `mix assets.build`
  passed. JS check reported zero errors and two existing unused catch-parameter
  warnings in the unchanged asset entry.
- Browser checks covered both themes, desktop and 390px mobile layouts, search,
  account selection, contact creation, source/month navigation, event creation,
  UTC → all-day → UTC roundtrip, and named icon controls. No page horizontal
  overflow or browser console errors were observed in the checked states.
- Preview uses a separate fixture database with Oban disabled on port 4396.
  Real configured-account data and provider connections were not modified.
