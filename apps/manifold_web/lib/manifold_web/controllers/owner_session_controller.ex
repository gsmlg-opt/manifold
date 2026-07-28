defmodule ManifoldWeb.OwnerSessionController do
  use ManifoldWeb, :controller

  alias Manifold.Accounts
  alias ManifoldWeb.OwnerAuth

  def new(conn, _params) do
    html(conn, login_form(nil))
  end

  def create(conn, %{"owner" => %{"email" => email, "password" => password}}) do
    case Accounts.get_owner_by_email_and_password(email, password) do
      nil ->
        conn
        |> put_resp_header("content-type", "text/html; charset=utf-8")
        |> send_resp(401, login_form("Invalid email or password"))

      owner ->
        conn
        |> OwnerAuth.log_in_owner(owner)
        |> redirect(to: "/deliveries")
    end
  end

  def delete(conn, _params), do: OwnerAuth.log_out_owner(conn)

  defp login_form(error) do
    csrf = Plug.CSRFProtection.get_csrf_token()

    error_html =
      if error, do: ~s(<p class="error">#{Phoenix.HTML.html_escape(error)}</p>), else: ""

    """
    <!doctype html>
    <html>
      <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Manifold Sign In</title>
        <link rel="stylesheet" href="/assets/app.css">
      </head>
      <body class="manifold-auth">
        <main class="auth-panel">
          <h1>Manifold</h1>
          #{error_html}
          <form method="post" action="/login">
            <input type="hidden" name="_csrf_token" value="#{csrf}">
            <label>Email <input type="email" name="owner[email]" required></label>
            <label>Password <input type="password" name="owner[password]" required></label>
            <button type="submit">Sign in</button>
          </form>
        </main>
      </body>
    </html>
    """
  end
end
