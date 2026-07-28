defmodule ManifoldWeb.Router do
  use ManifoldWeb, :router

  import ManifoldWeb.OwnerAuth

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {ManifoldWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
    plug(:fetch_current_owner)
  end

  scope "/", ManifoldWeb do
    pipe_through(:browser)

    get("/login", OwnerSessionController, :new)
    post("/login", OwnerSessionController, :create)
    delete("/logout", OwnerSessionController, :delete)

    live_session :owner,
      on_mount: [{ManifoldWeb.OwnerAuth, :ensure_authenticated}] do
      live("/", DeliveryLive.Index, :index)
      live("/domains", DomainLive.Index, :index)
      live("/mailboxes", MailboxLive.Index, :index)
      live("/aliases", AliasLive.Index, :index)
      live("/deliveries", DeliveryLive.Index, :index)
      live("/deliveries/:id", DeliveryLive.Show, :show)
    end
  end
end
