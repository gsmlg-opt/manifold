defmodule Manifold.Connectors.OAuthProviderCatalogTest do
  use ExUnit.Case, async: true

  alias Manifold.Connectors.OAuthProviderCatalog
  alias Manifold.Core.Error

  test "catalog exposes Gmail followed by Microsoft 365 settings providers" do
    assert [%{key: "gmail", name: "Gmail"} = gmail, %{key: "microsoft", name: "Microsoft 365"}] =
             OAuthProviderCatalog.list()

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

    assert {:ok, microsoft} = OAuthProviderCatalog.fetch("microsoft")

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
             authorization_url:
               "https://login.microsoftonline.com/organizations/oauth2/v2.0/authorize",
             token_url: "https://login.microsoftonline.com/organizations/oauth2/v2.0/token",
             base_url: "https://graph.microsoft.com/v1.0",
             tenant: "organizations"
           ]

    assert microsoft.help.configuration_title == "Microsoft OAuth"
    assert microsoft.help.documentation_name == "Microsoft"

    assert Enum.any?(microsoft.help.steps, &String.contains?(&1, "work/school"))

    assert Enum.any?(
             microsoft.help.steps,
             &String.contains?(&1, "Do not add Mail.ReadWrite")
           )
  end

  test "unknown providers return a permanent error without creating atoms" do
    provider = "unknown-provider-#{System.unique_integer([:positive])}"

    assert_raise ArgumentError, fn -> String.to_existing_atom(provider) end

    assert {:error, %Error{class: :permanent, reason: :unsupported_provider}} =
             OAuthProviderCatalog.fetch(provider)

    assert_raise ArgumentError, fn -> String.to_existing_atom(provider) end
  end
end
