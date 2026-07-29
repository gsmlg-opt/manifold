defmodule Manifold.Security.EvaluatorTest do
  use ExUnit.Case, async: true

  alias Manifold.Security.{Evaluation, Evaluator, Input}

  defmodule AuthenticationAdapter do
    @behaviour Manifold.Security.AuthenticationAdapter

    @impl true
    def evaluate(_config, _input) do
      {:ok, %{spf: :pass, dkim: :fail, dmarc: :pass, metadata: %{"source" => "test"}}}
    end
  end

  defmodule MalwareAdapter do
    @behaviour Manifold.Security.MalwareAdapter

    @impl true
    def scan(_config, _input),
      do: {:ok, %{verdict: :infected, signature: "EICAR", metadata: %{}}}
  end

  defmodule SpamAdapter do
    @behaviour Manifold.Security.SpamAdapter

    @impl true
    def classify(_config, _input),
      do: {:ok, %{verdict: :spam, score: 0.95, metadata: %{}}}
  end

  test "default adapters explicitly return not evaluated" do
    assert {:ok, %Evaluation{} = evaluation} = Evaluator.evaluate(input())
    assert evaluation.spf == :not_evaluated
    assert evaluation.dkim == :not_evaluated
    assert evaluation.dmarc == :not_evaluated
    assert evaluation.malware.verdict == :not_evaluated
    assert evaluation.spam.verdict == :not_evaluated
    assert evaluation.policy_action == :allow
    assert evaluation.policy_reasons == []
  end

  test "normalizes adapter evidence and applies policy" do
    assert {:ok, evaluation} =
             Evaluator.evaluate(input(),
               authentication_adapter: AuthenticationAdapter,
               malware_adapter: MalwareAdapter,
               spam_adapter: SpamAdapter,
               spam_threshold: 0.9
             )

    assert evaluation.spf == :pass
    assert evaluation.dkim == :fail
    assert evaluation.dmarc == :pass
    assert evaluation.malware.signature == "EICAR"
    assert evaluation.spam.score == 0.95
    assert evaluation.policy_action == :quarantine
    assert evaluation.policy_reasons == [:malware, :spam]
  end

  test "rejects invalid adapter result values instead of fabricating an outcome" do
    invalid = fn _config, _input ->
      {:ok, %{spf: :trusted, dkim: :pass, dmarc: :pass, metadata: %{}}}
    end

    assert {:error, %{class: :permanent, reason: :invalid_security_result}} =
             Evaluator.evaluate(input(), authentication_adapter: invalid)
  end

  defp input do
    %Input{
      inbound_delivery_id: Ecto.UUID.generate(),
      peer_ip: "192.0.2.10",
      helo: "sender.example",
      envelope_from: "sender@example.net",
      received_at: ~U[2026-07-29 08:00:00Z],
      raw_object_key: "raw/trusted/message.eml",
      raw_size: 123,
      raw_sha256: String.duplicate("0", 64)
    }
  end
end
