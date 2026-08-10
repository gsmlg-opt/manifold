# SMTP Send Method Form Style Design

**Date:** 2026-08-10

**Status:** Approved for planning

**Scope:** SMTP send-method form presentation only; no form behavior, validation, or connector changes

## Goal

Make the SMTP send-method form match the existing IMAP and EAS forms. Labels and
controls should render as a constrained vertical form with full-width themed
inputs, consistent focus states, hint typography, and action spacing.

## Root Cause

The SMTP template already uses the same label, input, select, and footer structure
as the IMAP form. Its `#smtp-send-method-form` ID is omitted from the shared CSS
selector groups in `apps/manifold_web/assets/css/app.css`, so browser-default inline
styles appear instead.

## Design

Add `#smtp-send-method-form` to the existing shared selector groups for:

- form grid, maximum width, gap, and top margin;
- label layout and typography;
- label hint typography;
- input and select sizing, surfaces, borders, and text;
- input and select focus treatment; and
- action sizing and spacing.

Reuse the current DuskMoon design tokens and responsive panel behavior without
introducing new CSS declarations or changing HEEX markup.

## Alternatives Considered

1. Add a new shared class to every protocol form. This would improve selector
   naming but expand the change across otherwise-correct templates.
2. Refactor all fields to DuskMoon form components. This is broader than the
   visual regression and risks unrelated behavior changes.

The selected approach is the smallest change and preserves the proven IMAP/EAS
presentation exactly.

## Behavior and Error Handling

SMTP validation, test-connection, save, busy, notice, error, and navigation
behavior remain unchanged. Existing error and success messages keep their current
styles.

## Testing

- Build frontend assets to validate the CSS bundle.
- Run the scoped account LiveView test covering SMTP send-method creation.
- Run the formatter check.
- Confirm the final diff is limited to the shared selector additions, this design
  record, the implementation plan, and the required feature reference update.

## Acceptance Criteria

- [ ] SMTP fields are stacked vertically and use the same width and spacing as IMAP/EAS.
- [ ] SMTP input and select controls use the same DuskMoon surfaces, borders, and focus states.
- [ ] Hint text and footer actions match IMAP/EAS.
- [ ] The form remains usable at the existing narrow-screen breakpoint.
- [ ] SMTP behavior is unchanged.
