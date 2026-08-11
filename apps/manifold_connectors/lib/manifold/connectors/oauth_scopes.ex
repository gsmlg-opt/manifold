defmodule Manifold.Connectors.OAuthScopes do
  @moduledoc false

  alias Manifold.Connectors.{GmailScopes, MicrosoftScopes}

  def identity("gmail"), do: ["openid", "email"]
  def identity("microsoft"), do: ["openid", "profile", "User.Read"]

  def purpose("gmail", :receive), do: {:ok, [GmailScopes.read()]}
  def purpose("gmail", :send), do: {:ok, [GmailScopes.send()]}

  def purpose("microsoft", :receive),
    do: {:ok, [MicrosoftScopes.read(), MicrosoftScopes.offline()]}

  def purpose("microsoft", :send), do: {:ok, [MicrosoftScopes.send(), MicrosoftScopes.offline()]}
  def purpose(_provider, _purpose), do: :error

  def method_scope("gmail", :receive), do: {:ok, GmailScopes.read()}
  def method_scope("gmail", :send), do: {:ok, GmailScopes.send()}
  def method_scope("microsoft", :receive), do: {:ok, MicrosoftScopes.read()}
  def method_scope("microsoft", :send), do: {:ok, MicrosoftScopes.send()}
  def method_scope(_provider, _purpose), do: :error

  def approved?("gmail", scope), do: scope in [GmailScopes.read(), GmailScopes.send()]

  def approved?("microsoft", scope),
    do: scope in [MicrosoftScopes.read(), MicrosoftScopes.send(), MicrosoftScopes.offline()]

  def approved?(_provider, _scope), do: false
end
