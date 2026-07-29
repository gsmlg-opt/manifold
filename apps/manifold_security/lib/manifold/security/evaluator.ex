defmodule Manifold.Security.Evaluator do
  @moduledoc """
  Runs configured adapters and normalizes their evidence for persistence.
  """

  alias Manifold.Core.Error

  alias Manifold.Security.Adapters.{
    NotEvaluatedAuthentication,
    NotEvaluatedMalware,
    NotEvaluatedSpam
  }

  alias Manifold.Security.{Evaluation, Input, Policy}

  @authentication_results ~w(pass fail softfail neutral none temperror permerror not_evaluated)a
  @malware_verdicts ~w(clean infected suspicious temperror not_evaluated)a
  @spam_verdicts ~w(ham spam temperror not_evaluated)a

  @spec evaluate(Input.t(), Keyword.t()) :: {:ok, Evaluation.t()} | {:error, Error.t()}
  def evaluate(%Input{} = input, opts \\ []) do
    authentication_adapter = authentication_adapter(input, opts)

    malware_adapter = Keyword.get(opts, :malware_adapter, NotEvaluatedMalware)
    spam_adapter = Keyword.get(opts, :spam_adapter, NotEvaluatedSpam)
    adapter_config = Keyword.get(opts, :adapter_config, [])

    with {:ok, authentication} <-
           invoke(authentication_adapter, :evaluate, adapter_config, input),
         :ok <- validate_authentication(authentication),
         {:ok, malware} <- invoke(malware_adapter, :scan, adapter_config, input),
         :ok <- validate_malware(malware),
         {:ok, spam} <- invoke(spam_adapter, :classify, adapter_config, input),
         :ok <- validate_spam(spam) do
      results = %{
        spf: authentication.spf,
        dkim: authentication.dkim,
        dmarc: authentication.dmarc,
        malware: malware,
        spam: spam
      }

      {policy_action, policy_reasons} =
        Policy.decide(results, spam_threshold: Keyword.get(opts, :spam_threshold, 0.9))

      {:ok,
       %Evaluation{
         spf: authentication.spf,
         dkim: authentication.dkim,
         dmarc: authentication.dmarc,
         authentication_metadata: Map.get(authentication, :metadata, %{}),
         malware: malware,
         spam: spam,
         policy_action: policy_action,
         policy_reasons: policy_reasons
       }}
    end
  end

  defp invoke(adapter, _callback, config, input) when is_function(adapter, 2),
    do: adapter.(config, input)

  defp invoke(adapter, callback, config, input) when is_atom(adapter),
    do: apply(adapter, callback, [config, input])

  defp authentication_adapter(%Input{source_kind: "provider_import"}, _opts),
    do: NotEvaluatedAuthentication

  defp authentication_adapter(%Input{}, opts),
    do: Keyword.get(opts, :authentication_adapter, NotEvaluatedAuthentication)

  defp validate_authentication(authentication) when is_map(authentication) do
    if Enum.all?([:spf, :dkim, :dmarc], &(Map.get(authentication, &1) in @authentication_results)) do
      :ok
    else
      invalid_result()
    end
  end

  defp validate_authentication(_authentication), do: invalid_result()

  defp validate_malware(%{verdict: verdict}) when verdict in @malware_verdicts, do: :ok
  defp validate_malware(_malware), do: invalid_result()

  defp validate_spam(%{verdict: verdict, score: score}) when verdict in @spam_verdicts do
    if is_nil(score) or (is_number(score) and score >= 0.0 and score <= 1.0) do
      :ok
    else
      invalid_result()
    end
  end

  defp validate_spam(_spam), do: invalid_result()

  defp invalid_result do
    {:error,
     Error.new(
       :permanent,
       :invalid_security_result,
       "security adapter returned an invalid result"
     )}
  end
end
