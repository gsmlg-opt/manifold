# Add Account UI Design

## Goal

Make external email account setup discoverable from `/settings/accounts` through
an explicit **Add account** flow. The flow connects a Gmail or Microsoft 365
account to one existing active local Manifold mailbox.

## Scope

This change affects only the external-account settings LiveView, its scoped
tests, and the styles used by that view. It reuses the existing connector
context and OAuth controller routes. It does not change connector persistence,
OAuth semantics, provider scopes, local mailbox creation, or connected-account
management.

## User Flow

The page header contains a primary **Add account** button. Activating it opens
an inline setup panel above the connected-accounts table:

1. The user selects **External account** as the account type.
2. The user selects **Gmail** or **Microsoft 365**.
3. The user selects an active local mailbox and continues.
4. Continue navigates to the existing provider OAuth start route with the
   selected mailbox ID.

The panel includes **Back** and **Cancel** controls. Back returns to the previous
step without changing persistent state. Cancel closes the panel and resets its
temporary selections.

The existing local-mailbox connector table is removed. Local mailbox
administration remains available through the existing **Mailboxes** settings
navigation.

## Availability and Empty States

Both supported providers remain visible in the provider step. A provider whose
OAuth configuration is unavailable is disabled and labeled **Provider not
configured**.

Only active local mailboxes are offered as destinations. If none exist, the
mailbox step explains that a local mailbox is required, links to **Manage
mailboxes**, and does not render an OAuth continuation action.

## LiveView State

The LiveView owns transient wizard state:

- Current step: closed, account type, provider, or mailbox.
- Selected provider.
- Selected mailbox ID.

LiveView events only move between steps, update selections, or reset the
wizard. Provider API calls remain outside LiveView. The final continuation is a
normal link to the existing OAuth controller, preserving the current OAuth and
PKCE boundary.

## Accessibility

The panel has a descriptive heading and step label. Provider and account-type
choices use native buttons with clear disabled states. The mailbox choice uses
a labeled native select. Back, Cancel, and Continue have visible text, and
disabled providers include a textual reason rather than relying on color.

## Testing

Scoped LiveView tests will verify:

- The settings page exposes **Add account** instead of per-mailbox provider
  links.
- The wizard advances from external account to provider to mailbox.
- Gmail and Microsoft 365 are visible, while unconfigured providers are
  disabled and explained.
- Only active mailboxes are selectable.
- The final OAuth URL contains the chosen provider and mailbox ID.
- No active mailboxes produces the management link and no OAuth continuation.
- Back and Cancel reset or preserve transient state as designed.
