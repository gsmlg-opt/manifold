defmodule ManifoldWeb.Formatting do
  @moduledoc """
  Shared display formatters for LiveViews.
  """

  @doc """
  Formats a datetime as `YYYY-MM-DD HH:MM` (UTC wall clock of the given value).

  Returns an empty string for nil.
  """
  @spec datetime(DateTime.t() | NaiveDateTime.t() | nil) :: String.t()
  def datetime(nil), do: ""

  def datetime(%DateTime{} = datetime) do
    Calendar.strftime(datetime, "%Y-%m-%d %H:%M")
  end

  def datetime(%NaiveDateTime{} = datetime) do
    Calendar.strftime(datetime, "%Y-%m-%d %H:%M")
  end

  @doc """
  Formats a datetime as `YYYY-MM-DD HH:MM UTC`.
  """
  @spec datetime_utc(DateTime.t() | nil) :: String.t()
  def datetime_utc(nil), do: ""

  def datetime_utc(%DateTime{} = datetime) do
    Calendar.strftime(datetime, "%Y-%m-%d %H:%M UTC")
  end

  @doc """
  Formats an ISO-8601 timestamp string as `YYYY-MM-DD HH:MM`.

  Falls back to the original string when parsing fails.
  """
  @spec datetime_iso(String.t() | nil) :: String.t()
  def datetime_iso(nil), do: ""

  def datetime_iso(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, datetime, _offset} -> datetime(datetime)
      {:error, _} -> iso
    end
  end
end
