defmodule Manifold.SMTP.RateLimit do
  @moduledoc """
  Pure fixed-window rate-limit transitions for SMTP admission.
  """

  @enforce_keys [:started_at_ms, :count]
  defstruct [:started_at_ms, :count]

  @type t :: %__MODULE__{started_at_ms: integer(), count: non_neg_integer()}

  @spec check(t() | nil, pos_integer() | :infinity, pos_integer(), integer()) ::
          {:ok, t() | nil} | {:error, non_neg_integer(), t()}
  def check(window, :infinity, _window_ms, _now_ms), do: {:ok, window}

  def check(window, limit, window_ms, now_ms)
      when is_integer(limit) and limit > 0 and is_integer(window_ms) and window_ms > 0 do
    window = current_window(window, window_ms, now_ms)

    if window.count < limit do
      {:ok, %{window | count: window.count + 1}}
    else
      retry_after_ms = max(window_ms - (now_ms - window.started_at_ms), 0)
      {:error, retry_after_ms, window}
    end
  end

  @spec expired?(t(), pos_integer(), integer()) :: boolean()
  def expired?(%__MODULE__{} = window, window_ms, now_ms) do
    now_ms - window.started_at_ms >= window_ms
  end

  defp current_window(nil, _window_ms, now_ms),
    do: %__MODULE__{started_at_ms: now_ms, count: 0}

  defp current_window(%__MODULE__{} = window, window_ms, now_ms) do
    if now_ms - window.started_at_ms >= window_ms do
      %__MODULE__{started_at_ms: now_ms, count: 0}
    else
      window
    end
  end
end
