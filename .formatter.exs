[
  import_deps: [:ecto, :phoenix],
  plugins: [Phoenix.LiveView.HTMLFormatter],
  inputs: [
    "{mix,.formatter}.exs",
    "{config,apps}/**/*.{ex,exs}",
    "apps/*/{lib,test}/**/*.{ex,exs,heex}"
  ]
]
