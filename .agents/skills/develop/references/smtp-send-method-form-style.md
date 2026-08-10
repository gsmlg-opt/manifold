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
