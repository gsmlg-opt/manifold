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

  scope "/webhooks", ManifoldWeb do
    post("/providers/resend", ResendWebhookController, :create)
  end

  scope "/", ManifoldWeb do
    pipe_through(:browser)

    get("/connectors/:provider/start", ConnectorOAuthController, :start)
    get("/connectors/:provider/callback", ConnectorOAuthController, :callback)

    live_session :local_instance do
      live("/", MailLive.Index, :home)
      live("/mail", MailLive.Index, :home)
      live("/mail/:mailbox_id/drafts", MailLive.Index, :drafts)
      live("/mail/:mailbox_id/drafts/:draft_id/edit", MailLive.Index, :draft_edit)
      live("/mail/:mailbox_id/sent", MailLive.Index, :sent)
      live("/mail/:mailbox_id/sent/:outbound_message_id", MailLive.Index, :sent_detail)
      live("/mail/:mailbox_id/folders/:folder_id", MailLive.Index, :folder)

      live(
        "/mail/:mailbox_id/folders/:folder_id/threads/:thread_id",
        MailLive.Index,
        :conversation
      )

      live("/deliveries", DeliveryLive.Index, :index)
      live("/deliveries/:id", DeliveryLive.Show, :show)
      live("/jobs", JobLive.Index, :index)
      live("/cloud", CloudLive.Index, :index)
      live("/settings/accounts", AccountLive.Index, :index)
      live("/settings/accounts/new", AccountLive.New, :new)
      live("/settings/accounts/:id/edit", AccountLive.Edit, :edit)
      live("/settings/accounts/:id/receive_methods/new", AccountLive.ReceiveMethodNew, :new)
      live("/settings/accounts/:id/send_methods/new", AccountLive.SendMethodNew, :new)
      live("/settings/accounts/:id", AccountLive.Show, :show)
      live("/settings/accounts/:id/activity", ExternalAccountLive.Activity, :show)
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
