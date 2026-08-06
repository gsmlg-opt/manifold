# Manifold Web UI Design

Visual and styling constraints for `manifold_web`. Product/architecture design lives in [`docs/DESIGN.md`](docs/DESIGN.md).

**Stack:** Phoenix LiveView + [phoenix_duskmoon](https://hex.pm/packages/phoenix_duskmoon) + Duskmoon Bundler + Tailwind.

**Themes:** `sunshine` (light) and `moonlight` (dark). Auto resolves via `prefers-color-scheme` when the user has not picked an explicit theme.

Agents and contributors must follow this document when adding or changing HEEX, CSS, or layout code.

---

## 1. Required setup (do not drift)

### CSS entry (`apps/manifold_web/assets/css/app.css`)

```css
@import "tailwindcss";
@plugin "@duskmoon-dev/core/plugin";
@import "@duskmoon-dev/core/themes/sunshine";
@import "@duskmoon-dev/core/themes/moonlight";
@import "@duskmoon-dev/core/components";
@import "../../../../deps/phoenix_duskmoon/assets/css/element-theme-bridge.css";
```

Both themes must stay imported. Do not remove either, and do not invent a third named theme.

### HTML root

```heex
<html lang="en" data-theme="sunshine">
<body class="bg-surface text-on-surface min-h-screen">
```

- Theme is applied on `<html data-theme="…">`.
- Allowed resolved values: `sunshine` | `moonlight`.
- Stored preference may be `default` (auto), `sunshine`, or `moonlight` in `localStorage.theme`.
- Keep the antiflicker script in `root.html.heex` that reads `localStorage` before paint.

### App shell

```heex
<div class="app-shell min-h-screen bg-surface text-on-surface">
  <.dm_appbar class="appbar-primary appbar-sticky" …>
    …
    <:user_profile>
      <.dm_theme_switcher id="app-theme-switcher" phx-update="ignore" />
    </:user_profile>
  </.dm_appbar>
  <main class="content">{@inner_content}</main>
</div>
```

| Piece | Required |
|-------|----------|
| Appbar | `appbar-primary` + `appbar-sticky` — background `--color-primary`, text `--color-primary-content` |
| Theme switcher | Always in appbar right (`:user_profile`); `phx-update="ignore"` so LiveView morph does not reset it |
| Page body | `bg-surface` / `text-on-surface` |
| Assets | Build with `mix duskmoon_bundler.build manifold_web --tailwind` (via `mix assets.build`) |

### Theme persistence (non-negotiable)

1. Prefer client `localStorage.theme`; do **not** pass `theme="default"` (or any server theme) into `<.dm_theme_switcher>` in a way that clobbers localStorage on mount.
2. `ManifoldWeb.Hooks.Theme` may handle `theme_changed` but must not force a concrete theme assign into the switcher.
3. Never reintroduce a moonlight-only override that paints the appbar with `surface-container-*` instead of `primary`.
4. Avoid JS that breaks the whole `app.js` graph (e.g. class private methods that pull `@oxc-project/runtime` 404s) — ThemeSwitcher never mounts if the bundle fails.

---

## 2. Theme roles

| Theme | Role | Notes |
|-------|------|--------|
| `sunshine` | Light | Default antiflicker fallback when auto cannot run |
| `moonlight` | Dark | MD3-style tokens; `primary` may read near-light — still use primary for appbar |
| `default` (stored) | Auto | Resolve to moonlight/sunshine from `prefers-color-scheme`; do not leave `data-theme="default"` on `<html>` after resolve |

Moonlight appbar looking pale is **token design**, not a bug. Do not “fix” it by switching the appbar off primary.

---

## 3. Color rules

### Use tokens only

All colors come from Duskmoon CSS variables / utilities.

| Do | Don’t |
|----|--------|
| `var(--color-surface)`, `bg-surface`, `text-on-surface` | `#fff`, `#087156`, `rgb(…)`, named colors |
| `bg-primary text-primary-content` | `bg-blue-500`, `text-slate-600`, Tailwind palette scales |
| `border-outline-variant` | Hardcoded grey borders |
| `surface-container*` elevation | `bg-white/80`, opacity-faked whites |

When writing custom CSS in `app.css`, prefer:

```css
background: var(--color-surface-container);
color: var(--color-on-surface);
border-color: var(--color-outline-variant);
```

### Pair background + text

| Background | Text |
|------------|------|
| `primary` | `primary-content` |
| `secondary` | `secondary-content` |
| `tertiary` | `tertiary-content` |
| `surface` / `surface-container-*` | `on-surface` |
| `primary-container` | `on-primary-container` |
| `error` / `error-container` | `error-content` / `on-error-container` |
| `success` / `success-container` | `success-content` / `on-success-container` |

### Surface elevation (low → high)

```
surface                    page / body
  secondary                mail sidebar / drawers (nav identity)
  surface-container        cards, tables, mail list/detail panes
    surface-container-high   table headers, elevated panels, menus
      surface-container-highest  dialogs, strong emphasis, message body shells
```

Never nest a lower elevation inside a higher one.

### Semantic colors

`success` / `warning` / `error` / `info` are for **state only** (flash, validation, badges). Not for branding or primary CTAs.

### One primary action per view

One clear `primary` CTA. Cancel / secondary use `ghost`, `outline`, or `secondary`.

---

## 4. Component defaults (Manifold)

Prefer `dm_*` components from phoenix_duskmoon when one exists.

| Surface | Pattern |
|---------|---------|
| Appbar | `<.dm_appbar class="appbar-primary appbar-sticky">` |
| Theme | `<.dm_theme_switcher phx-update="ignore" />` |
| Icons | `<.dm_mdi …>` — inherit `currentColor` |
| Buttons | `dm_btn` variants: `primary` / `secondary` / `ghost` / `outline` / `error` |
| Cards / panels | `surface-container` + `outline-variant` border |
| Tables | `surface-container` body, `surface-container-high` header, `on-surface` text |
| Forms / wizards | Panel on `surface-container`; inputs on `surface-container-highest` + `outline` |
| Flash | `success-container` / `error-container` (and on-* text) |
| Mail sidebar | `secondary` / `secondary-content` (or project `.webmail` token mapping equivalent) |
| Mail list / detail | `surface-container` panes; selected row `primary-container` / `on-primary-container` |
| Compose / Send | `primary` / `primary-content` |

### Mail HTML body

Untrusted message HTML in iframes may keep sender styles. Theme the **chrome** (panes, chrome chrome, headers, actions). Do not force app tokens into arbitrary HTML mail unless there is an explicit sanitizer/bridge strategy.

---

## 5. Typography

Defined in `app.css` / `root.html.heex`:

| Role | Family |
|------|--------|
| Body | DM Sans → `--font-body` |
| Display / headings | Fraunces → `--font-display` |
| Mono | JetBrains Mono → `--font-mono` |

Do not replace with Inter, Roboto, Arial, or bare `system-ui` as the intentional brand stack.

Hierarchy:

- Page title: display font, one per page
- Body / UI chrome: body font
- Muted copy: `on-surface-variant`
- Metadata / timestamps: smaller + `on-surface-variant`

---

## 6. Layout density

| View type | Density |
|-----------|---------|
| Settings, accounts, forms | Content spacing (`p-6`–level), clear sections |
| Mail three-pane | Dense data UI — compact lists, fixed panes |
| Operations / tables | Dense tables with token borders |

Keep one gap scale per view. Do not mix decorative card grids into the mail client chrome.

---

## 7. Motion

- Theme and color transitions: ~`0.2s ease` on background/color/border when motion is allowed.
- Always honor `prefers-reduced-motion: reduce` (already in `app.css`).
- Prefer subtle hover on interactive rows/cards; no heavy glow stacks or purple gradient chrome.

---

## 8. Anti-patterns (reject in review)

1. Hardcoded hex/rgb or Tailwind palette colors for themeable UI.
2. White cards / tables on moonlight page background (token mismatch → light text on light panels).
3. Appbar not on `primary` (including moonlight “make it dark with surface” overrides).
4. Passing server `theme="default"` into the theme switcher and wiping localStorage.
5. Building UI that only looks correct in sunshine.
6. Custom spinners / one-off icon color systems when `dm_*` covers the case.
7. Styling untrusted HTML mail with global app CSS.
8. JS private class fields/methods in asset entry modules that break duskmoon_bundler / oxc runtime loading.

---

## 9. Checklist before merging UI work

- [ ] Looks correct in **sunshine** and **moonlight**
- [ ] No new hardcoded theme colors in HEEX/CSS for app chrome
- [ ] Appbar still `appbar-primary`; theme switcher still present and persistent
- [ ] Soft LiveView navigation + hard refresh keep the selected theme
- [ ] Assets rebuilt if CSS/JS changed (`mix assets.build` / duskmoon_bundler)
- [ ] Mail chrome themed; HTML body iframe limitation acknowledged if relevant

---

## 10. Key files

| File | Responsibility |
|------|----------------|
| `apps/manifold_web/assets/css/app.css` | Token imports, project chrome, webmail/table/form tokens |
| `apps/manifold_web/lib/manifold_web/components/layouts/root.html.heex` | `data-theme`, fonts, antiflicker |
| `apps/manifold_web/lib/manifold_web/components/layouts/app.html.heex` | Appbar + theme switcher |
| `apps/manifold_web/lib/manifold_web/hooks/theme.ex` | `theme_changed` hook (no forced default theme) |
| `apps/manifold_web/assets/js/app.js` | LiveSocket + ThemeSwitcher / localStorage preference |
| `config/config.exs` | Tailwind content paths including phoenix_duskmoon |
