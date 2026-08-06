defmodule Manifold.Connectors.SMTP.Fake do
  @moduledoc false

  @behaviour Manifold.Connectors.SMTP.Transport

  alias Manifold.Connectors.Provider.Error

  @impl true
  def connect(settings) when is_map(settings) do
    bump_connect_count(settings)
    expected = Map.get(settings, :password_expected)

    if is_binary(expected) and settings.password != expected do
      {:error,
       %Error{
         class: :reconnect,
         code: :auth_failed,
         message: "SMTP authentication failed"
       }}
    else
      {:ok, pid} = Agent.start_link(fn -> %{settings: settings} end)
      {:ok, pid}
    end
  end

  @impl true
  def quit(conn) when is_pid(conn) do
    Agent.stop(conn)
    :ok
  end

  defp bump_connect_count(settings) do
    case Map.get(settings, :connect_count) do
      counter when is_pid(counter) -> Agent.update(counter, &(&1 + 1))
      _ -> :ok
    end
  end
end
