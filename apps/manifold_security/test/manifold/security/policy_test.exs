defmodule Manifold.Security.PolicyTest do
  use ExUnit.Case, async: true

  alias Manifold.Security.Policy

  test "disabled integrations remain explicitly not evaluated and allow delivery" do
    results = %{
      spf: :not_evaluated,
      dkim: :not_evaluated,
      dmarc: :not_evaluated,
      malware: %{verdict: :not_evaluated},
      spam: %{verdict: :not_evaluated}
    }

    assert {:allow, []} = Policy.decide(results, spam_threshold: 0.9)
    refute Enum.any?([results.spf, results.dkim, results.dmarc], &(&1 == :pass))
  end

  test "positive malware evidence quarantines" do
    results = base_results(%{malware: %{verdict: :infected, signature: "test-signature"}})

    assert {:quarantine, [:malware]} = Policy.decide(results, spam_threshold: 0.9)
  end

  test "spam quarantines only at the configured threshold" do
    below = base_results(%{spam: %{verdict: :spam, score: 0.89}})
    at_threshold = base_results(%{spam: %{verdict: :spam, score: 0.9}})

    assert {:allow, []} = Policy.decide(below, spam_threshold: 0.9)
    assert {:quarantine, [:spam]} = Policy.decide(at_threshold, spam_threshold: 0.9)
  end

  test "authentication failure is recorded without automatic quarantine" do
    results = base_results(%{spf: :fail, dkim: :fail, dmarc: :fail})

    assert {:allow, []} = Policy.decide(results, spam_threshold: 0.9)
  end

  test "multiple positive signals have deterministic reason order" do
    results =
      base_results(%{
        malware: %{verdict: :infected},
        spam: %{verdict: :spam, score: 1.0}
      })

    assert {:quarantine, [:malware, :spam]} =
             Policy.decide(results, spam_threshold: 0.9)
  end

  defp base_results(overrides) do
    Map.merge(
      %{
        spf: :not_evaluated,
        dkim: :not_evaluated,
        dmarc: :not_evaluated,
        malware: %{verdict: :not_evaluated},
        spam: %{verdict: :not_evaluated}
      },
      overrides
    )
  end
end
