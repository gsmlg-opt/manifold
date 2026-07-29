defmodule ManifoldWeb.MessageBodyController do
  use ManifoldWeb, :controller

  alias Manifold.Core.Error
  alias Manifold.Mail

  @csp "default-src 'none'; img-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'; frame-ancestors 'self'"

  def show(conn, %{"mailbox_id" => mailbox_id, "message_id" => message_id}) do
    case Mail.get_message_body(mailbox_id, message_id) do
      {:ok, body} ->
        document =
          """
          <!doctype html>
          <html>
            <head>
              <meta charset="utf-8">
              <meta name="referrer" content="no-referrer">
              <base target="_blank">
              <style>
                :root { color-scheme: light dark; }
                body { margin: 0; padding: 16px; font: 15px/1.55 system-ui, sans-serif; overflow-wrap: anywhere; }
                table { max-width: 100%; }
                pre { white-space: pre-wrap; }
              </style>
            </head>
            <body>#{body}</body>
          </html>
          """

        conn
        |> put_resp_content_type("text/html", "utf-8")
        |> put_resp_header("content-security-policy", @csp)
        |> put_resp_header("x-content-type-options", "nosniff")
        |> put_resp_header("cache-control", "private, no-store")
        |> send_resp(200, document)

      {:error, %Error{class: :temporary}} ->
        send_resp(conn, 503, "Message body temporarily unavailable")

      {:error, _reason} ->
        send_resp(conn, 404, "Message body not found")
    end
  end
end
