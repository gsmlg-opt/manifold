defmodule Manifold.Connectors.OAuthProvider.Gmail do
  @moduledoc false

  @definition %{
    key: "gmail",
    name: "Gmail",
    icon: "gmail",
    callback_path: "/connectors/gmail/callback",
    capabilities: [:receive, :send],
    scopes: [
      "email",
      "https://www.googleapis.com/auth/gmail.readonly",
      "https://www.googleapis.com/auth/gmail.send",
      "openid"
    ],
    runtime_config: [
      authorization_url: "https://accounts.google.com/o/oauth2/v2/auth",
      token_url: "https://oauth2.googleapis.com/token",
      userinfo_url: "https://openidconnect.googleapis.com/v1/userinfo",
      base_url: "https://gmail.googleapis.com"
    ],
    help: %{
      title: "Set up Google OAuth",
      steps: [
        "Create or select a Google Cloud project.",
        "Enable the Gmail API.",
        "Configure OAuth branding and audience.",
        "Add Manifold's required scopes.",
        "Add test users when the app is in Testing mode.",
        "Create a Web application OAuth client.",
        "Register the exact callback URI shown below.",
        "Save the client ID and secret in Manifold."
      ],
      links: [
        {"Manage app audience", "https://support.google.com/cloud/answer/15549945?hl=en"},
        {"OAuth verification", "https://support.google.com/cloud/answer/13463073?hl=en"},
        {"Request minimum scopes", "https://support.google.com/cloud/answer/13807380?hl=en"}
      ]
    }
  }

  @spec definition() :: map()
  def definition, do: @definition
end
