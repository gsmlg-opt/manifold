defmodule Manifold.Connectors.OAuthProviderCatalogTest do
  use ExUnit.Case, async: true

  alias Manifold.Connectors.OAuthProviderCatalog
  alias Manifold.Core.Error

  test "catalog exposes Gmail followed by Microsoft 365 settings providers" do
    assert [
             %{key: "gmail", name: "Gmail"} = gmail,
             %{key: "microsoft", name: "Microsoft 365"} = microsoft
           ] = OAuthProviderCatalog.list()

    assert gmail.icon == "gmail"
    assert gmail.callback_path == "/connectors/gmail/callback"
    assert gmail.capabilities == [:receive, :send]

    assert gmail.scopes == [
             "email",
             "https://www.googleapis.com/auth/gmail.readonly",
             "https://www.googleapis.com/auth/gmail.send",
             "openid"
           ]

    assert gmail.runtime_config == [
             authorization_url: "https://accounts.google.com/o/oauth2/v2/auth",
             token_url: "https://oauth2.googleapis.com/token",
             userinfo_url: "https://openidconnect.googleapis.com/v1/userinfo",
             base_url: "https://gmail.googleapis.com"
           ]

    assert gmail.help == %{
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
               {"Request minimum scopes",
                "https://support.google.com/cloud/answer/13807380?hl=en"}
             ]
           }

    assert {:ok, ^gmail} = OAuthProviderCatalog.fetch("gmail")

    assert {:ok, ^microsoft} = OAuthProviderCatalog.fetch("microsoft")

    assert microsoft.icon == "microsoft"
    assert microsoft.callback_path == "/connectors/microsoft/callback"
    assert microsoft.capabilities == [:receive, :send]

    assert microsoft.scopes == [
             "openid",
             "profile",
             "User.Read",
             "Mail.Read",
             "Mail.Send",
             "offline_access"
           ]

    assert microsoft.runtime_config == [
             authorization_url: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize",
             token_url: "https://login.microsoftonline.com/common/oauth2/v2.0/token",
             base_url: "https://graph.microsoft.com/v1.0",
             tenant: "common"
           ]

    assert microsoft.help == %{
             title: "Set up Microsoft OAuth",
             configuration_title: "Microsoft OAuth",
             documentation_name: "Microsoft",
             steps: [
               "Create or select a Microsoft Entra application registration.",
               "Select accounts in any organizational directory and personal Microsoft accounts for work/school and Outlook.com access.",
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
               %{
                 value: "Mail.Read",
                 purpose: "Receive mail without modifying the remote mailbox."
               },
               %{value: "Mail.Send", purpose: "Send mail as the signed-in user."},
               %{
                 value: "offline_access",
                 purpose: "Refresh the delegated grant when access expires."
               }
             ],
             testing_note:
               "Use non-production Microsoft 365 work/school or personal Outlook.com accounts.",
             production_note:
               "The common authority accepts work/school and personal Microsoft accounts when the application registration supports both; work/school tenant policy may require administrator consent.",
             links: [
               {"Register an Entra application",
                "https://learn.microsoft.com/en-us/entra/identity-platform/quickstart-register-app"},
               {"Configure a redirect URI",
                "https://learn.microsoft.com/en-us/entra/identity-platform/how-to-add-redirect-uri"},
               {"Microsoft Graph permissions",
                "https://learn.microsoft.com/en-us/graph/permissions-reference"},
               {"Supported account types",
                "https://learn.microsoft.com/en-us/entra/identity-platform/howto-modify-supported-accounts"}
             ]
           }
  end

  test "Microsoft device-code setup supports work/school and personal account audiences" do
    assert {:ok, microsoft} = OAuthProviderCatalog.fetch("microsoft")

    assert "Select accounts in any organizational directory and personal Microsoft accounts for work/school and Outlook.com access." in microsoft.device_help.steps

    assert microsoft.device_help.testing_note ==
             "Use non-production Microsoft 365 work/school or personal Outlook.com accounts."

    assert microsoft.device_help.production_note == microsoft.help.production_note

    assert "Under Authentication, enable Allow public client flows." in microsoft.device_help.steps

    assert "No callback URL or client secret is needed." in microsoft.device_help.steps
  end

  test "unknown providers return a permanent error without creating atoms" do
    provider = "unknown-provider-#{System.unique_integer([:positive])}"

    assert_raise ArgumentError, fn -> String.to_existing_atom(provider) end

    assert {:error, %Error{class: :permanent, reason: :unsupported_provider}} =
             OAuthProviderCatalog.fetch(provider)

    assert_raise ArgumentError, fn -> String.to_existing_atom(provider) end
  end
end
