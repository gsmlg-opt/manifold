defmodule Manifold.Outbound.State do
  @moduledoc """
  Pure outbound lifecycle validation and provider-event reduction.
  """

  alias Manifold.Core.Error

  @states ~w(
    draft
    queued
    submitting
    accepted_by_provider
    failed
    submission_uncertain
  )

  @transitions %{
    "draft" => ~w(queued),
    "queued" => ~w(submitting failed submission_uncertain),
    "submitting" => ~w(queued accepted_by_provider failed submission_uncertain),
    "accepted_by_provider" => [],
    "failed" => [],
    "submission_uncertain" => []
  }

  @recipient_precedence %{
    "pending" => 0,
    "sent" => 10,
    "delayed" => 15,
    "delivered" => 20,
    "failed" => 25,
    "bounced" => 30,
    "complained" => 40,
    "suppressed" => 50
  }

  @spec states() :: [String.t()]
  def states, do: @states

  @spec validate_transition(String.t(), String.t()) :: :ok | {:error, Error.t()}
  def validate_transition(from, to) when is_binary(from) and is_binary(to) do
    if to in Map.get(@transitions, from, []) do
      :ok
    else
      {:error,
       Error.new(:permanent, :invalid_state_transition, "invalid outbound state transition", %{
         from: from,
         to: to
       })}
    end
  end

  @spec apply_recipient_event(String.t(), DateTime.t() | nil, String.t(), DateTime.t()) ::
          {:ok, {String.t(), DateTime.t() | nil}} | {:error, Error.t()}
  def apply_recipient_event(current, current_at, event_state, %DateTime{} = event_at)
      when is_binary(current) do
    with {:ok, event_rank} <- recipient_rank(event_state) do
      current_rank = Map.get(@recipient_precedence, current, 0)

      if newer_or_equal?(event_at, current_at) and event_rank > current_rank do
        {:ok, {event_state, event_at}}
      else
        {:ok, {current, current_at}}
      end
    end
  end

  defp recipient_rank(state) do
    case Map.fetch(@recipient_precedence, state) do
      {:ok, rank} ->
        {:ok, rank}

      :error ->
        {:error,
         Error.new(:permanent, :unknown_provider_event, "unknown outbound provider event", %{
           state: state
         })}
    end
  end

  defp newer_or_equal?(_event_at, nil), do: true
  defp newer_or_equal?(event_at, current_at), do: DateTime.compare(event_at, current_at) != :lt
end
