[
  import_deps: [:ecto, :phoenix],
  plugins: [Phoenix.LiveView.HTMLFormatter, DuskmoonBundler.Formatter],
  inputs: [
    "{mix,.formatter}.exs",
    "{config,apps}/**/*.{ex,exs}",
    "apps/*/{lib,test}/**/*.{ex,exs,heex}",
    "apps/manifold_web/assets/**/*.{js,ts,jsx,tsx}"
  ]
]
