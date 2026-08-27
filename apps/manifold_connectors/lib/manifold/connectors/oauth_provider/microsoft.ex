defmodule Manifold.Connectors.OAuthProvider.Microsoft do
  @moduledoc false

  @definition %{
    key: "microsoft",
    name: "Microsoft 365",
    icon: "microsoft",
    callback_path: "/connectors/microsoft/callback",
    capabilities: [:receive, :send],
    scopes: ["openid", "profile", "User.Read", "Mail.Read", "Mail.Send", "offline_access"],
    runtime_config: [
      authorization_url: "https://login.microsoftonline.com/organizations/oauth2/v2.0/authorize",
      token_url: "https://login.microsoftonline.com/organizations/oauth2/v2.0/token",
      base_url: "https://graph.microsoft.com/v1.0",
      tenant: "organizations"
    ],
    help: %{
      title: "Set up Microsoft OAuth",
      configuration_title: "Microsoft OAuth",
      documentation_name: "Microsoft",
      steps: [
        "Create or select an Entra application registration.",
        "Select Accounts in any organizational directory for work/school accounts.",
        "Add a Web callback URI using the exact address shown below.",
        "Add delegated User.Read, Mail.Read, and Mail.Send permissions.",
        "Do not add Mail.ReadWrite; Manifold does not create or modify Graph drafts.",
        "Allow offline_access.",
        "Create and copy a client secret.",
        "Copy the application client ID and secret into Settings OAuth.",
        "Obtain tenant admin consent if required."
      ],
      scopes: [
        %{value: "openid", purpose: "Sign in with the Microsoft identity platform."},
        %{value: "profile", purpose: "Read basic profile information."},
        %{value: "User.Read", purpose: "Read the signed-in user's profile."},
        %{value: "Mail.Read", purpose: "Receive mail without modifying messages."},
        %{value: "Mail.Send", purpose: "Send mail through Microsoft Graph."},
        %{value: "offline_access", purpose: "Maintain access by refreshing authorization tokens."}
      ],
      testing_note:
        "Use non-production Microsoft 365 work/school accounts; personal Outlook.com accounts are not supported.",
      production_note:
        "The organizations tenant accepts work/school identities, and tenant policy may require admin consent.",
      links: [
        {"Register an Entra application",
         "https://learn.microsoft.com/en-us/entra/identity-platform/quickstart-register-app"},
        {"Configure a redirect URI",
         "https://learn.microsoft.com/en-us/entra/identity-platform/how-to-add-redirect-uri"},
        {"Microsoft Graph permissions",
         "https://learn.microsoft.com/en-us/graph/permissions-reference"},
        {"Supported organizational account types",
         "https://learn.microsoft.com/en-us/entra/identity-platform/howto-modify-supported-accounts"}
      ]
    }
  }

  @spec definition() :: map()
  def definition, do: @definition
end
