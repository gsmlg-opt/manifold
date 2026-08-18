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
      configuration_title: "Google OAuth",
      documentation_name: "Google",
      steps: [
        "Create or select a Google Cloud project.",
        "Enable the Gmail API.",
        "Configure OAuth branding and audience.",
        "Add only openid, email, gmail.readonly, and gmail.send.",
        "Add test users when the app is in Testing mode.",
        "Create a Web application OAuth client.",
        "Register the exact callback URI shown below.",
        "Copy the client ID and secret into Settings OAuth.",
        "Complete Google verification before public use when required."
      ],
      scopes: [
        %{value: "openid", purpose: "Confirm the Google account identity."},
        %{value: "email", purpose: "Read the Google account email address."},
        %{
          value: "https://www.googleapis.com/auth/gmail.readonly",
          purpose: "Receive mail by reading Gmail messages without modifying them."
        },
        %{
          value: "https://www.googleapis.com/auth/gmail.send",
          purpose: "Send mail through Gmail."
        }
      ],
      testing_note: "Testing-mode authorizations can expire after seven days.",
      production_note:
        "Sensitive or restricted scopes may require Google verification before public use.",
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
