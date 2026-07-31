# Local Mailbox Creation UI Design

## Goal

Make local mailbox setup possible from the web UI. The `/mailboxes` page will
provide a focused flow that selects an existing domain or creates one when
needed, then creates the mailbox.

The flow also completes the missing handoff from external-account setup: when a
user needs to create a local mailbox while adding Gmail or Microsoft 365, the
new mailbox will be selected automatically when they return.

## Scope

This change covers:

- An inline create-mailbox flow on `/mailboxes`.
- New-domain creation within that flow.
- Inline validation errors from the existing domain and mailbox changesets.
- A trusted return path from the external-account wizard.
- Scoped Accounts and LiveView tests.
- Responsive and accessible styles for the new controls.

Editing or deleting domains and mailboxes is not included. The existing active
and plus-addressing defaults remain unchanged. No database migration or change
to mailbox delivery behavior is required.

## Mailboxes Page

The `/mailboxes` header gains a primary **Create mailbox** button. Activating it
opens an inline setup panel above the current mailbox table. The table remains
visible so the page retains its management context.

The panel has two steps:

1. **Choose or create a domain.** If domains exist, the user can select one. A
   **Create a new domain** choice reveals a required domain-name field. If no
   domains exist, new-domain creation is shown directly.
2. **Create the mailbox.** The user enters the required local part and an
   optional display name. The page shows the complete resulting address using
   the selected or newly created domain.

The panel provides **Back** and **Cancel** controls. Back returns to domain
selection. Cancel closes the panel and clears transient form state. Focus moves
to each step heading as the panel advances and returns to the create button
when the panel closes.

## Persistence and Validation

The LiveView calls the existing `Manifold.Accounts.create_domain/1` and
`Manifold.Accounts.create_mailbox/2` context functions. Their changesets remain
the source of truth for domain normalization, address syntax, required fields,
and uniqueness.

A selected existing domain advances immediately to the mailbox step. A new
domain is persisted when its valid domain form is submitted, then becomes the
selected domain for the mailbox step. If the user cancels afterward, the domain
remains because it is a valid independently managed routing resource.

Invalid submissions keep the current step open and display field errors. A
mailbox is added to the table only after successful persistence. A normal
successful creation closes the panel, refreshes the list, and displays a
confirmation flash.

## External-Account Handoff

When the external-account wizard reaches its local-mailbox step with no active
mailboxes, its action changes from **Manage mailboxes** to **Create local
mailbox**. The link carries only an allowlisted flow marker and the already
validated provider identifier.

After a mailbox is created from that entry point, the LiveView navigates to
`/settings/accounts` with the provider and new mailbox ID. The external-account
LiveView validates that:

- The provider is Gmail or Microsoft 365 and is currently configured.
- The mailbox ID belongs to an active mailbox under an active domain.

When both checks pass, the wizard opens at its mailbox step with the new
mailbox selected and the provider continuation action ready. Invalid or stale
parameters fail closed and render the normal accounts page without opening or
preselecting the wizard. The application will not accept an arbitrary return
URL.

## LiveView State

The mailbox LiveView owns only temporary setup state:

- Whether the create panel is open.
- Current step: domain or mailbox.
- Domain mode: existing or new.
- Selected domain.
- Domain and mailbox forms.
- Whether the request came from the external-account flow and its provider.

Step-specific event handlers enforce the expected current step so crafted
events cannot bypass domain selection or create a mailbox against an
unvalidated domain.

## Accessibility and Responsive Behavior

All fields use visible labels and native inputs or selects. Validation messages
are associated with their fields. Step headings receive programmatic focus,
and buttons have visible action text. Disabled and error states are not
communicated by color alone.

On narrow screens, the address preview and action row stack without horizontal
overflow. The existing mailbox table keeps its current responsive scrolling
behavior.

## Testing

Scoped tests will verify:

- `/mailboxes` exposes **Create mailbox** and opens and cancels the panel.
- With no domains, the flow starts with new-domain creation.
- With existing domains, the user can select one or choose to create another.
- Domain normalization, invalid names, and duplicate names surface through the
  form.
- The mailbox step validates required and malformed local parts and duplicate
  addresses.
- Successful creation refreshes the list and uses existing active and
  plus-addressing defaults.
- Back cannot bypass the domain step, and unexpected events fail closed.
- A normal successful flow remains on `/mailboxes`.
- An external-account flow returns to `/settings/accounts` with the new active
  mailbox selected.
- Invalid provider, mailbox, or handoff parameters do not restore the external
  wizard.
