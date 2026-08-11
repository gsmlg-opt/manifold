defmodule Manifold.Connectors.GmailScopes do
  @moduledoc false

  @read "https://www.googleapis.com/auth/gmail.readonly"
  @send "https://www.googleapis.com/auth/gmail.send"

  @spec read() :: String.t()
  def read, do: @read

  @spec send() :: String.t()
  def send, do: @send
end
