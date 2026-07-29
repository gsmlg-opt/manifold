defmodule Manifold.Security.Policy do
  @moduledoc """
  Pure quarantine policy for normalized security evidence.
  """

  @type decision :: {:allow, []} | {:quarantine, [:malware | :spam]}

  @spec decide(map(), Keyword.t()) :: decision()
  def decide(results, opts \\ []) when is_map(results) do
    spam_threshold = Keyword.get(opts, :spam_threshold, 0.9)

    reasons =
      []
      |> maybe_add(:malware, infected?(results))
      |> maybe_add(:spam, spam?(results, spam_threshold))

    case reasons do
      [] -> {:allow, []}
      reasons -> {:quarantine, reasons}
    end
  end

  defp infected?(%{malware: %{verdict: :infected}}), do: true
  defp infected?(_results), do: false

  defp spam?(%{spam: %{verdict: :spam, score: score}}, threshold)
       when is_number(score) and is_number(threshold),
       do: score >= threshold

  defp spam?(_results, _threshold), do: false

  defp maybe_add(reasons, reason, true), do: reasons ++ [reason]
  defp maybe_add(reasons, _reason, false), do: reasons
end
