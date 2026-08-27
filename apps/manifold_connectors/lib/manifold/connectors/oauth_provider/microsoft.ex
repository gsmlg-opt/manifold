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
        "Create or select a Microsoft Entra application registration.",
        "Select accounts in any organizational directory for work/school access.",
        "Add a Web platform and register the exact callback URI shown below.",
        "Add delegated User.Read, Mail.Read, and Mail.Send permissions.",
        "Do not add Mail.ReadWrite; Manifold does not create or modify Graph drafts.",
        "Allow offline_access so Manifold can refresh the delegated grant.",
        "Create a client secret and copy its value before leaving the Entra page.",
        "Copy the application client ID and secret into Settings OAuth.",
        "Obtain tenant administrator consent when the tenant policy requires it."
      ],
      scopes: [
        %{value: "openid", purpose: "Confirm the Microsoft identity."},
        %{value: "profile", purpose: "Read the signed-in account profile."},
        %{value: "User.Read", purpose: "Read and bind the signed-in Graph identity."},
        %{value: "Mail.Read", purpose: "Receive mail without modifying the remote mailbox."},
        %{value: "Mail.Send", purpose: "Send mail as the signed-in user."},
        %{value: "offline_access", purpose: "Refresh the delegated grant when access expires."}
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
