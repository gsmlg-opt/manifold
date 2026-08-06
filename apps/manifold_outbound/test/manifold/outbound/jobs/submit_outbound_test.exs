defmodule Manifold.Outbound.Jobs.SubmitOutboundTest do
  use Manifold.DataCase, async: false

  alias Manifold.Accounts
  alias Manifold.Outbound
  alias Manifold.Outbound.Jobs.SubmitOutbound
  alias Manifold.Outbound.Provider
  alias Manifold.Outbound.Schema.OutboundMessage
  alias Manifold.Repo

  defmodule ConfiguredProvider do
    @behaviour Manifold.Outbound.Provider

    @impl true
    def submit(config, _envelope), do: Keyword.fetch!(config, :result)
  end

  setup do
    old_adapter = Application.get_env(:manifold_outbound, :provider_adapter)
    old_config = Application.get_env(:manifold_outbound, :provider_config)

    Application.put_env(:manifold_outbound, :provider_adapter, ConfiguredProvider)

    on_exit(fn ->
      restore_env(:provider_adapter, old_adapter)
      restore_env(:provider_config, old_config)
    end)
  end

  test "completes after managed provider acceptance" do
    message = queued_message_fixture()

    Application.put_env(
      :manifold_outbound,
      :provider_config,
      result: {:ok, %Provider.Submission{provider_message_id: "worker-ok", metadata: %{}}}
    )

    assert :ok = SubmitOutbound.perform(job(message.id))
    assert Repo.get!(OutboundMessage, message.id).state == "accepted_by_provider"
  end

  test "returns transient errors to Oban for retry" do
    message = queued_message_fixture()

    Application.put_env(
      :manifold_outbound,
      :provider_config,
      result:
        {:error,
         %Provider.Error{
           class: :transient,
           code: "http_503",
           message: "later",
           http_status: 503
         }}
    )

    assert {:error, "http_503"} = SubmitOutbound.perform(job(message.id))
    assert Repo.get!(OutboundMessage, message.id).state == "queued"
  end

  test "snoozes until a provider rate limit expires" do
    message = queued_message_fixture()

    Application.put_env(
      :manifold_outbound,
      :provider_config,
      result:
        {:error,
         %Provider.Error{
           class: :transient,
           code: "http_429",
           message: "slow down",
           http_status: 429,
           retry_after: 75
         }}
    )

    assert {:snooze, 75} = SubmitOutbound.perform(job(message.id))
    assert Repo.get!(OutboundMessage, message.id).state == "queued"
  end

  test "completes terminal failures after persisting failed state" do
    message = queued_message_fixture()

    Application.put_env(
      :manifold_outbound,
      :provider_config,
      result:
        {:error,
         %Provider.Error{
           class: :permanent,
           code: "validation_error",
           message: "bad sender",
           http_status: 422
         }}
    )

    assert :ok = SubmitOutbound.perform(job(message.id))
    assert Repo.get!(OutboundMessage, message.id).state == "failed"
  end

  defp job(message_id), do: %Oban.Job{args: %{"outbound_message_id" => message_id}}

  defp queued_message_fixture do
    suffix = System.unique_integer([:positive])
    {:ok, domain} = Accounts.create_domain(%{name: "worker#{suffix}.test"})
    {:ok, mailbox} = Accounts.create_account(domain, %{local_part: "inbox"})

    {:ok, draft} =
      Outbound.create_draft(mailbox.id, %{
        subject: "Worker",
        text_body: "Body",
        recipients: [%{kind: "to", address: "person@example.net"}]
      })

    {:ok, queued} = Outbound.queue_draft(mailbox.id, draft.id)
    queued
  end

  defp restore_env(key, nil), do: Application.delete_env(:manifold_outbound, key)
  defp restore_env(key, value), do: Application.put_env(:manifold_outbound, key, value)
end
