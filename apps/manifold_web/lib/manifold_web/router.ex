defmodule ManifoldWeb.Router do
  use ManifoldWeb, :router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {ManifoldWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  scope "/", ManifoldWeb do
    pipe_through(:browser)

    live_session :local_instance do
      live("/", MailLive.Index, :home)
      live("/mail", MailLive.Index, :home)
      live("/mail/:mailbox_id/folders/:folder_id", MailLive.Index, :folder)

      live(
        "/mail/:mailbox_id/folders/:folder_id/threads/:thread_id",
        MailLive.Index,
        :conversation
      )

      live("/domains", DomainLive.Index, :index)
      live("/mailboxes", MailboxLive.Index, :index)
      live("/aliases", AliasLive.Index, :index)
      live("/deliveries", DeliveryLive.Index, :index)
      live("/deliveries/:id", DeliveryLive.Show, :show)
    end

    get(
      "/mailboxes/:mailbox_id/messages/:message_id/body",
      MessageBodyController,
      :show
    )

    get(
      "/mailboxes/:mailbox_id/attachments/:attachment_id",
      AttachmentController,
      :show
    )
  end
end
