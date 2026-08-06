defmodule ManifoldWeb.CoreComponents do
  @moduledoc false

  use Phoenix.Component

  attr(:flash, :map, default: %{})

  def flash_group(assigns) do
    ~H"""
    <div class="flash-group">
      <p :if={Phoenix.Flash.get(@flash, :info)} class="flash info">
        {Phoenix.Flash.get(@flash, :info)}
      </p>
      <p :if={Phoenix.Flash.get(@flash, :error)} class="flash error">
        {Phoenix.Flash.get(@flash, :error)}
      </p>
    </div>
    """
  end

  @doc """
  Renders an absolute timestamp that the browser reformats to the local timezone.

  Server-side text is UTC wall-clock as a no-JS fallback; `<mf-datetime>` replaces
  it with the browser-local `YYYY-MM-DD HH:MM` (or `date` / `time` via `format`).
  """
  attr(:value, :any, default: nil, doc: "DateTime, NaiveDateTime, or nil")
  attr(:format, :string, default: "datetime", values: ~w(datetime date time))
  attr(:rest, :global)

  def datetime(%{value: nil} = assigns) do
    ~H""
  end

  def datetime(assigns) do
    ~H"""
    <mf-datetime datetime={datetime_iso(@value)} format={@format} {@rest}>
      {ManifoldWeb.Formatting.datetime(@value)}
    </mf-datetime>
    """
  end

  defp datetime_iso(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp datetime_iso(%NaiveDateTime{} = datetime), do: NaiveDateTime.to_iso8601(datetime) <> "Z"
  defp datetime_iso(other) when is_binary(other), do: other
end
