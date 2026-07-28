defmodule ManifoldWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :manifold_web

  @session_options [
    store: :cookie,
    key: "_manifold_key",
    signing_salt: "manifold-session-salt",
    same_site: "Lax"
  ]

  socket("/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: [connect_info: [session: @session_options]]
  )

  plug(Plug.Static,
    at: "/",
    from: :manifold_web,
    gzip: false,
    only: ManifoldWeb.static_paths()
  )

  if code_reloading? do
    socket("/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket)
    plug(Phoenix.LiveReloader)
    plug(Phoenix.CodeReloader)

    plug(DuskmoonBundler.DevServer,
      profile: :manifold_web,
      root: "apps/manifold_web/assets",
      prefix: "/assets"
    )
  end

  plug(Plug.RequestId)
  plug(Plug.Telemetry, event_prefix: [:phoenix, :endpoint])

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()
  )

  plug(Plug.MethodOverride)
  plug(Plug.Head)
  plug(Plug.Session, @session_options)
  plug(ManifoldWeb.Router)
end
