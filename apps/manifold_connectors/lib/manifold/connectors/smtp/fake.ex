defmodule Manifold.Connectors.SMTP.Fake do
  @moduledoc false

  @behaviour Manifold.Connectors.SMTP.Transport

  alias Manifold.Connectors.Provider.Error

  @impl true
  def connect(settings) when is_map(settings) do
    bump_connect_count(settings)
    notify(settings, {:smtp_fake_connect, settings})
    expected = Map.get(settings, :password_expected)

    cond do
      is_binary(expected) and settings.password != expected ->
        {:error,
         %Error{
           class: :reconnect,
           code: :auth_failed,
           message: "SMTP authentication failed"
         }}

      match?({:error, %Error{}}, Map.get(settings, :connect_result)) ->
        Map.fetch!(settings, :connect_result)

      true ->
        {:ok, pid} = Agent.start_link(fn -> %{settings: settings} end)
        {:ok, pid}
    end
  end

  @impl true
  def submit(conn, submission) when is_pid(conn) and is_map(submission) do
    settings = Agent.get(conn, & &1.settings)
    notify(settings, {:smtp_fake_submit, submission})
    Map.get(settings, :submit_result, {:ok, %{response: "250 accepted"}})
  end

  @impl true
  def quit(conn) when is_pid(conn) do
    settings = Agent.get(conn, & &1.settings)
    notify(settings, :smtp_fake_quit)
    Agent.stop(conn)

    case Map.get(settings, :quit_result, :ok) do
      :raise ->
        notify(settings, :smtp_fake_quit_failure)
        raise "scripted SMTP QUIT failure"

      :ok ->
        :ok
    end
  end

  defp bump_connect_count(settings) do
    case Map.get(settings, :connect_count) do
      counter when is_pid(counter) -> Agent.update(counter, &(&1 + 1))
      _ -> :ok
    end
  end

  defp notify(settings, message) do
    case Map.get(settings, :event_pid) do
      pid when is_pid(pid) -> send(pid, message)
      _missing -> :ok
    end
  end
end
