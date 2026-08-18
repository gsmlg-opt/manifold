defmodule Manifold.Connectors.OAuthProviderCatalogTest do
  use ExUnit.Case, async: true

  alias Manifold.Connectors.OAuthProviderCatalog
  alias Manifold.Core.Error

  test "catalog exposes Gmail as the first and only settings provider" do
    assert [%{key: "gmail", name: "Gmail"} = gmail] = OAuthProviderCatalog.list()

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
               {"Request minimum scopes",
                "https://support.google.com/cloud/answer/13807380?hl=en"}
             ]
           }

    assert {:ok, ^gmail} = OAuthProviderCatalog.fetch("gmail")
  end

  test "unknown providers return a permanent error without creating atoms" do
    provider = "unknown-provider-#{System.unique_integer([:positive])}"

    assert_raise ArgumentError, fn -> String.to_existing_atom(provider) end

    assert {:error, %Error{class: :permanent, reason: :unsupported_provider}} =
             OAuthProviderCatalog.fetch(provider)

    assert_raise ArgumentError, fn -> String.to_existing_atom(provider) end
  end
end
