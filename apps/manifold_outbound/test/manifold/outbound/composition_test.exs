defmodule Manifold.Outbound.CompositionTest do
  use ExUnit.Case, async: true

  alias Manifold.Outbound.Composition

  @source %{
    message_id: "018f5f6e-3d31-7ef0-a5b6-2a3ed1647601",
    rfc_message_id: "<source@example.net>",
    references: ["<parent@example.net>"],
    subject: "Project update",
    sender: %{display_name: "Sender", address: "sender@example.net"},
    reply_to: [%{display_name: "Replies", address: "reply@example.net"}],
    to: [
      %{display_name: "Local", address: "Inbox@Example.Test"},
      %{display_name: "Teammate", address: "team@example.net"}
    ],
    cc: [
      %{display_name: "Duplicate", address: "TEAM@example.net"},
      %{display_name: "Observer", address: "observer@example.net"}
    ],
    sent_at: ~U[2026-07-29 04:30:00Z],
    text_body: "Original body"
  }

  test "reply targets Reply-To and preserves RFC threading references" do
    assert {:ok, draft} =
             Composition.prepare(:reply, @source, "inbox@example.test")

    assert draft.composition_kind == "reply"
    assert draft.source_message_id == @source.message_id
    assert draft.subject == "Re: Project update"
    assert draft.in_reply_to == "<source@example.net>"
    assert draft.references == ["<parent@example.net>", "<source@example.net>"]

    assert [%{address: "reply@example.net"}] = draft.to
    assert draft.cc == []
    assert draft.bcc == []
    assert draft.text_body =~ "On 2026-07-29 04:30 UTC, Sender wrote:"
    assert draft.text_body =~ "> Original body"
  end

  test "reply-all excludes the local sender and deduplicates recipients deterministically" do
    assert {:ok, draft} =
             Composition.prepare(:reply_all, @source, "inbox@example.test")

    assert Enum.map(draft.to, &String.downcase(&1.address)) == [
             "reply@example.net",
             "team@example.net"
           ]

    assert Enum.map(draft.cc, &String.downcase(&1.address)) == ["observer@example.net"]
  end

  test "forward starts without recipients and does not add reply headers" do
    assert {:ok, draft} =
             Composition.prepare(:forward, @source, "inbox@example.test")

    assert draft.composition_kind == "forward"
    assert draft.subject == "Fwd: Project update"
    assert draft.to == []
    assert draft.cc == []
    assert draft.bcc == []
    assert draft.in_reply_to == nil
    assert draft.references == []
    assert draft.text_body =~ "---------- Forwarded message ----------"
    assert draft.text_body =~ "From: Sender <sender@example.net>"
  end

  test "does not duplicate existing reply and forward prefixes" do
    assert {:ok, reply} =
             Composition.prepare(:reply, %{@source | subject: "RE: Project update"}, "me@test")

    assert reply.subject == "RE: Project update"

    assert {:ok, forward} =
             Composition.prepare(:forward, %{@source | subject: "Fwd: Project update"}, "me@test")

    assert forward.subject == "Fwd: Project update"
  end
end
