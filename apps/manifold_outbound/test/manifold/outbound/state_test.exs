defmodule Manifold.Outbound.StateTest do
  use ExUnit.Case, async: true

  alias Manifold.Outbound.State

  test "validates the local submission lifecycle" do
    assert :ok = State.validate_transition("draft", "queued")
    assert :ok = State.validate_transition("queued", "submitting")
    assert :ok = State.validate_transition("submitting", "accepted_by_provider")
    assert :ok = State.validate_transition("submitting", "submission_uncertain")

    assert {:error, %{reason: :invalid_state_transition}} =
             State.validate_transition("accepted_by_provider", "queued")
  end

  test "provider events update each recipient without regressing terminal state" do
    older = ~U[2026-07-29 04:00:00Z]
    newer = ~U[2026-07-29 05:00:00Z]

    assert {:ok, {"bounced", ^newer}} =
             State.apply_recipient_event("sent", older, "bounced", newer)

    assert {:ok, {"bounced", ^newer}} =
             State.apply_recipient_event("bounced", newer, "delivered", newer)

    assert {:ok, {"complained", ^newer}} =
             State.apply_recipient_event("delivered", older, "complained", newer)

    assert {:ok, {"delivered", ^newer}} =
             State.apply_recipient_event("delivered", newer, "sent", older)
  end

  test "rejects unknown states and provider events" do
    assert {:error, %{reason: :invalid_state_transition}} =
             State.validate_transition("draft", "teleported")

    assert {:error, %{reason: :unknown_provider_event}} =
             State.apply_recipient_event(
               "sent",
               ~U[2026-07-29 04:00:00Z],
               "opened",
               ~U[2026-07-29 05:00:00Z]
             )
  end
end
