# SMTP Send Method Form Style Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the SMTP send-method form use the same vertical, themed presentation as the existing IMAP and EAS forms.

**Architecture:** Keep the existing LiveView markup and behavior unchanged. Extend the shared settings-form CSS selector groups to include `#smtp-send-method-form`, then record the implementation in the repository skill reference index.

**Tech Stack:** Phoenix LiveView, HEEX, DuskMoon design tokens, CSS, ExUnit

---

## File Map

- Modify `apps/manifold_web/assets/css/app.css`: include the SMTP form ID in the shared IMAP/EAS form selectors.
- Create `.agents/skills/develop/references/smtp-send-method-form-style.md`: record ownership, root cause, and verification for future maintenance.
- Verify `apps/manifold_web/test/manifold_web/account_live_test.exs`: run the existing SMTP send-method flow test without changing behavior assertions.

### Task 1: Reuse the Shared Protocol Form Styles

**Files:**
- Modify: `apps/manifold_web/assets/css/app.css:692-753`

- [x] **Step 1: Confirm the regression in the current selectors**

Run:

```bash
rg -n -A 64 '^\.mailbox-setup-form,' apps/manifold_web/assets/css/app.css
```

Expected: the six form-style selector groups contain `#imap-account-form` and `#eas-account-form`, but omit `#smtp-send-method-form`.

- [x] **Step 2: Add the SMTP form to all shared selector groups**

Add the following selectors alongside their IMAP equivalents, without changing any declarations:

```css
#smtp-send-method-form,
#smtp-send-method-form label,
#smtp-send-method-form label span,
#smtp-send-method-form input,
#smtp-send-method-form select,
#smtp-send-method-form input:focus,
#smtp-send-method-form select:focus,
#smtp-send-method-form .settings-action,
```

Expected placement:

- `#smtp-send-method-form` in the grid/layout group;
- `#smtp-send-method-form label` in the label group;
- `#smtp-send-method-form label span` in the hint group;
- both input and select selectors in the control group;
- both input and select focus selectors in the focus group; and
- the settings-action selector in the action group.

- [x] **Step 3: Check the CSS diff**

Run:

```bash
git diff --check
git diff -- apps/manifold_web/assets/css/app.css
```

Expected: no whitespace errors; the CSS diff only adds the eight selectors listed above.

### Task 2: Record the Feature Maintenance Note

**Files:**
- Create: `.agents/skills/develop/references/smtp-send-method-form-style.md`

- [x] **Step 1: Create the scoped feature reference**

Create the file with this content:

```markdown
# SMTP Send Method Form Style

## Scope

The SMTP send-method setup UI is owned by
`ManifoldWeb.AccountLive.SendMethodNew` and shares the settings form styles in
`apps/manifold_web/assets/css/app.css` with the IMAP and EAS setup forms.

## Implementation

- `#smtp-send-method-form` must remain in every shared protocol-form selector
  group: layout, labels, hints, controls, focus states, and actions.
- SMTP behavior remains in
  `apps/manifold_web/lib/manifold_web/live/account_live/send_method_new.ex`.
- Reuse DuskMoon surface, outline, and primary tokens already defined by the
  shared selectors; do not add protocol-specific color declarations.

## Verification

- `mix assets.build`
- `mix test apps/manifold_web/test/manifold_web/account_live_test.exs`
- `mix format --check-formatted`
```

- [x] **Step 2: Check the documentation diff**

Run:

```bash
git diff --check
git diff -- .agents/skills/develop/references/smtp-send-method-form-style.md
```

Expected: no placeholders or whitespace errors; the note names the LiveView, CSS ownership, and scoped verification commands.

### Task 3: Verify the Scoped Change

**Files:**
- Verify: `apps/manifold_web/assets/css/app.css`
- Test: `apps/manifold_web/test/manifold_web/account_live_test.exs`

- [x] **Step 1: Build the frontend assets**

Run:

```bash
mix assets.build
```

Expected: command exits with status 0 and produces the Manifold web CSS/JS bundles without errors.

- [x] **Step 2: Run the scoped account LiveView tests**

Run inside the repository Devenv shell or with its active test database variables:

```bash
mix test apps/manifold_web/test/manifold_web/account_live_test.exs
```

Expected: all tests pass, including `account show can add smtp send method`.

- [x] **Step 3: Run formatting and diff checks**

Run:

```bash
mix format --check-formatted
git diff --check
```

Expected: both commands exit with status 0.

- [x] **Step 4: Review final scope**

Run:

```bash
git status --short
git diff --stat
```

Expected: implementation changes are limited to `app.css`, the feature reference, and this implementation plan.

- [x] **Step 5: Commit the implementation**

Run:

```bash
git add apps/manifold_web/assets/css/app.css \
  .agents/skills/develop/references/smtp-send-method-form-style.md \
  docs/superpowers/plans/2026-08-10-smtp-form-style.md
git commit -m "fix(web): style SMTP send method form"
```

Expected: one conventional commit containing only the scoped CSS, maintenance note, and implementation plan.
