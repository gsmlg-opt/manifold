defmodule ManifoldAPI.Router do
  use ManifoldAPI, :router

  pipeline :api do
    plug(:accepts, ["json"])
  end

  scope "/", ManifoldAPI do
    pipe_through(:api)

    get("/.well-known/manifold", WellKnownController, :show)
  end

  scope "/api/v1", ManifoldAPI do
    pipe_through(:api)

    get("/health", HealthController, :show)
    get("/mailboxes", MailboxController, :index)
    get("/mailboxes/:mailbox_id/folders", FolderController, :index)

    get(
      "/mailboxes/:mailbox_id/folders/:folder_id/conversations",
      ConversationController,
      :index
    )

    get("/mailboxes/:mailbox_id/search", ConversationController, :search)
    get("/mailboxes/:mailbox_id/conversations/:thread_id", ConversationController, :show)
    get("/mailboxes/:mailbox_id/messages/:message_id/body", MessageBodyController, :show)
    get("/mailboxes/:mailbox_id/attachments/:attachment_id", AttachmentController, :show)
  end

  scope "/api" do
    pipe_through(:api)

    forward("/graphql", Absinthe.Plug, schema: ManifoldAPI.GraphQL.Schema)
  end

  if Mix.env() in [:dev, :test] do
    scope "/api" do
      forward("/graphiql", Absinthe.Plug.GraphiQL,
        schema: ManifoldAPI.GraphQL.Schema,
        interface: :simple
      )
    end
  end
end
