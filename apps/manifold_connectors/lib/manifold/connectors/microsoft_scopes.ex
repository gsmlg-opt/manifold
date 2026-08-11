defmodule Manifold.Connectors.MicrosoftScopes do
  @moduledoc false

  def read, do: "Mail.Read"
  def send, do: "Mail.Send"
  def offline, do: "offline_access"
end
