defmodule Manifold.Outbound.Submission do
  @moduledoc false

  import Ecto.Query

  alias Manifold.Core.Error
  alias Manifold.Outbound.Provider
  alias Manifold.Outbound.ProviderEvents
  alias Manifold.Outbound.Provider.Envelope

  alias Manifold.Outbound.Schema.{
    OutboundEvent,
    OutboundMessage,
    OutboundRecipient,
    ProviderSubmission
  }

  alias Manifold.Outbound.State
  alias Manifold.Repo

  @spec submit(Ecto.UUID.t(), Keyword.t()) ::
          :ok | {:error, Error.t() | Provider.Error.t()}
  def submit(message_id, opts \\ []) do
    provider =
      Keyword.get(
        opts,
        :provider,
        Application.get_env(
          :manifold_outbound,
          :provider_adapter,
          Manifold.Outbound.Provider.Resend
        )
      )

    provider_config =
      Keyword.get(
        opts,
        :provider_config,
        Application.get_env(:manifold_outbound, :provider_config, [])
      )

    with {:ok, preparation} <- prepare_attempt(message_id),
         result <- call_provider(preparation, provider, provider_config, opts) do
      persist_result(preparation, result, opts)
    end
  rescue
    DBConnection.ConnectionError ->
      {:error, Error.new(:temporary, :database_unavailable, "outbound database is unavailable")}
  end

  defp prepare_attempt(message_id) do
    Repo.transaction(fn ->
      message =
        OutboundMessage
        |> where([message], message.id == ^message_id)
        |> lock("FOR UPDATE")
        |> Repo.one()

      submission =
        ProviderSubmission
        |> where([submission], submission.outbound_message_id == ^message_id)
        |> lock("FOR UPDATE")
        |> Repo.one()

      prepare_locked(message, submission)
    end)
    |> case do
      {:ok, {:ready, message, submission}} ->
        {:ok,
         %{
           message_id: message.id,
           envelope: envelope(message, submission),
           submission_id: submission.id
         }}

      {:ok, :already_accepted} ->
        {:ok, :already_accepted}

      {:ok, {:error, %Error{} = error}} ->
        {:error, error}

      {:error, reason} ->
        {:error, database_error(reason)}
    end
  end

  defp prepare_locked(nil, _submission),
    do: {:error, Error.new(:permanent, :outbound_not_found, "outbound message not found")}

  defp prepare_locked(_message, nil),
    do: {:error, Error.new(:permanent, :submission_not_found, "provider submission not found")}

  defp prepare_locked(%OutboundMessage{state: "accepted_by_provider"}, _submission),
    do: :already_accepted

  defp prepare_locked(%OutboundMessage{state: state}, _submission)
       when state in ["failed", "submission_uncertain"] do
    {:error, Error.new(:permanent, :submission_not_retryable, "submission is not retryable")}
  end

  defp prepare_locked(message, submission) do
    now = DateTime.utc_now()

    if submission.attempt_count > 0 and
         DateTime.compare(now, submission.idempotency_expires_at) != :lt do
      mark_uncertain(message, submission, now)
    else
      start_attempt(message, submission, now)
    end
  end

  defp start_attempt(message, submission, now) do
    with :ok <- maybe_transition(message.state, "submitting") do
      message =
        message
        |> Ecto.Changeset.change(
          state: "submitting",
          last_error_class: nil,
          last_error_code: nil,
          last_error_message: nil
        )
        |> Repo.update!()

      submission =
        submission
        |> Ecto.Changeset.change(
          state: "submitting",
          attempt_count: submission.attempt_count + 1,
          first_attempt_at: submission.first_attempt_at || now,
          last_attempt_at: now,
          last_error_code: nil,
          last_error_message: nil
        )
        |> Repo.update!()

      insert_event!(message.id, "submission_started", %{attempt: submission.attempt_count}, now)
      {:ready, message, submission}
    end
  end

  defp mark_uncertain(message, submission, now) do
    message
    |> Ecto.Changeset.change(
      state: "submission_uncertain",
      last_error_class: "permanent",
      last_error_code: "idempotency_expired",
      last_error_message: "provider acceptance is ambiguous after idempotency expiry"
    )
    |> Repo.update!()

    submission
    |> Ecto.Changeset.change(
      state: "uncertain",
      last_error_code: "idempotency_expired",
      last_error_message: "provider acceptance is ambiguous after idempotency expiry"
    )
    |> Repo.update!()

    insert_event!(message.id, "submission_uncertain", %{}, now)

    {:error,
     Error.new(
       :permanent,
       :submission_uncertain,
       "submission was not retried after provider idempotency expired"
     )}
  end

  defp call_provider(:already_accepted, _provider, _config, _opts), do: :already_accepted

  defp call_provider(preparation, provider, config, opts) do
    result = provider.submit(config, preparation.envelope)

    if Keyword.get(opts, :fail_at) == :after_provider_accept_before_commit and
         match?({:ok, %Provider.Submission{}}, result) do
      {:injected_failure,
       Error.new(
         :temporary,
         :after_provider_accept_before_commit,
         "injected failure after provider acceptance"
       )}
    else
      result
    end
  end

  defp persist_result(:already_accepted, :already_accepted, _opts), do: :ok

  defp persist_result(_preparation, {:injected_failure, %Error{} = error}, _opts),
    do: {:error, error}

  defp persist_result(preparation, {:ok, %Provider.Submission{} = provider_submission}, opts) do
    now = DateTime.utc_now()

    result =
      Repo.transaction(fn ->
        {message, submission} = lock_submission!(preparation)
        maybe_fail(opts, :provider_accept_commit)

        unless message.state == "accepted_by_provider" do
          message
          |> Ecto.Changeset.change(state: "accepted_by_provider", accepted_at: now)
          |> Repo.update!()

          submission
          |> Ecto.Changeset.change(
            state: "accepted",
            provider_message_id: provider_submission.provider_message_id,
            accepted_at: now,
            provider_metadata: provider_submission.metadata
          )
          |> Repo.update!()

          insert_event!(
            message.id,
            "provider_accepted",
            %{provider_message_id: provider_submission.provider_message_id},
            now
          )

          ProviderEvents.reconcile_pending(
            submission.provider,
            provider_submission.provider_message_id,
            message.id,
            now
          )
        end
      end)

    case result do
      {:ok, _result} ->
        :telemetry.execute(
          [:manifold, :outbound, :submit, :stop],
          %{attempts: 1},
          %{outbound_message_id: preparation.message_id, outcome: :accepted}
        )

        :ok

      {:error, reason} ->
        {:error, database_error(reason)}
    end
  end

  defp persist_result(preparation, {:error, %Provider.Error{} = error}, opts) do
    now = DateTime.utc_now()
    state = if error.class == :transient, do: "queued", else: "failed"
    submission_state = if error.class == :transient, do: "pending", else: "failed"

    result =
      Repo.transaction(fn ->
        {message, submission} = lock_submission!(preparation)
        maybe_fail(opts, :provider_error_commit)

        message
        |> Ecto.Changeset.change(
          state: state,
          last_error_class: Atom.to_string(error.class),
          last_error_code: error.code,
          last_error_message: error.message,
          failed_at: if(error.class == :permanent, do: now)
        )
        |> Repo.update!()

        submission
        |> Ecto.Changeset.change(
          state: submission_state,
          last_http_status: error.http_status,
          last_error_code: error.code,
          last_error_message: error.message
        )
        |> Repo.update!()

        event_type =
          if error.class == :transient, do: "submission_retryable", else: "submission_failed"

        insert_event!(message.id, event_type, %{code: error.code}, now)
      end)

    case result do
      {:ok, _result} -> {:error, error}
      {:error, reason} -> {:error, database_error(reason)}
    end
  end

  defp lock_submission!(preparation) do
    message =
      OutboundMessage
      |> where([message], message.id == ^preparation.message_id)
      |> lock("FOR UPDATE")
      |> Repo.one!()

    submission =
      ProviderSubmission
      |> where([submission], submission.id == ^preparation.submission_id)
      |> lock("FOR UPDATE")
      |> Repo.one!()

    {message, submission}
  end

  defp envelope(message, submission) do
    recipients =
      OutboundRecipient
      |> where([recipient], recipient.outbound_message_id == ^message.id)
      |> order_by([recipient], asc: recipient.kind, asc: recipient.position)
      |> Repo.all()

    %Envelope{
      from: format_address(message.sender_name, message.sender_address),
      to: recipient_addresses(recipients, "to"),
      cc: recipient_addresses(recipients, "cc"),
      bcc: recipient_addresses(recipients, "bcc"),
      subject: message.subject,
      text: message.text_body || "",
      in_reply_to: message.in_reply_to,
      references: message.references,
      idempotency_key: submission.idempotency_key
    }
  end

  defp recipient_addresses(recipients, kind) do
    recipients
    |> Enum.filter(&(&1.kind == kind))
    |> Enum.map(&format_address(&1.display_name, &1.address))
  end

  defp format_address(name, address) when is_binary(name) and name != "" do
    clean_name = String.replace(name, ~r/[\r\n]/, " ")
    "#{clean_name} <#{address}>"
  end

  defp format_address(_name, address), do: address

  defp maybe_transition("submitting", "submitting"), do: :ok
  defp maybe_transition(from, to), do: State.validate_transition(from, to)

  defp insert_event!(message_id, event_type, metadata, now) do
    %OutboundEvent{}
    |> OutboundEvent.changeset(%{
      outbound_message_id: message_id,
      event_type: event_type,
      metadata: metadata,
      occurred_at: now
    })
    |> Repo.insert!()
  end

  defp maybe_fail(opts, boundary) do
    if Keyword.get(opts, :fail_at) == boundary do
      Repo.rollback({:injected_failure, boundary})
    end
  end

  defp database_error(reason) do
    Error.new(:temporary, :database_unavailable, "outbound database operation failed", %{
      reason: inspect(reason)
    })
  end
end
