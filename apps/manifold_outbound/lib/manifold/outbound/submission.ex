defmodule Manifold.Outbound.Submission do
  @moduledoc false

  import Ecto.Query

  alias Manifold.Connectors
  alias Manifold.Connectors.Provider.Error, as: ConnectorProviderError
  alias Manifold.Connectors.SubmissionMethod
  alias Manifold.Core.Error
  alias Manifold.Outbound.Provider
  alias Manifold.Outbound.ProviderEvents
  alias Manifold.Outbound.Provider.{Envelope, Request}
  alias Manifold.Outbound.RfcMessage

  alias Manifold.Outbound.Schema.{
    OutboundEvent,
    OutboundMessage,
    OutboundRecipient,
    ProviderSubmission
  }

  alias Manifold.Outbound.State
  alias Manifold.Repo

  @telemetry_error_codes MapSet.new(~w(
    acceptance_unknown
    account_disconnected
    authentication_expired
    auth_failed
    authorization_not_found
    bad_greeting
    bad_reply
    concurrent_idempotent_requests
    connect_failed
    credential_authentication_failed
    data_rejected
    database_unavailable
    domain_policy
    ehlo_failed
    gmail_reconnect_lifecycle_failed
    insufficient_scope
    insufficient_provider_scope
    interrupted_submission
    invalid_address
    invalid_config
    invalid_credential_envelope
    invalid_envelope_address
    invalid_encryption_key
    invalid_gmail_authorization
    invalid_grant
    invalid_idempotent_request
    invalid_message
    invalid_message_id
    invalid_provider_response
    invalid_response
    message_rejected
    not_found
    outbound_not_found
    provider_not_configured
    provider_unavailable
    rate_limited
    reconnect_required
    recv_failed
    recipient_rejected
    request_integrity_failed
    request_rejected
    reauthorization_required
    send_failed
    send_method_provider_mismatch
    send_method_required
    sender_rejected
    sender_address_mismatch
    smtp_error
    stale_submission_result
    starttls_failed
    submission_not_found
    submission_not_retryable
    submission_uncertain
    timeout
    tls_failed
    transport_error
    unexpected_exception
    unsupported_provider
  ))

  @spec submit(Ecto.UUID.t(), Keyword.t()) ::
          :ok | {:error, Error.t() | Provider.Error.t()}
  def submit(message_id, opts \\ []) do
    start = System.monotonic_time()

    case capture_submission(fn -> prepare_attempt(message_id, start) end) do
      {:return, prepared} ->
        submit_prepared(prepared, opts, start)

      {:database_error, result} ->
        emit_submit_stop(%{message_id: message_id, attempt_count: 0}, result, start)
        result

      {:exception, exception, stacktrace} ->
        emit_submit_stop(
          %{message_id: message_id, attempt_count: 0},
          unexpected_exception_result(),
          start
        )

        reraise(exception, stacktrace)
    end
  end

  defp submit_prepared({:ok, :already_accepted}, _opts, _start), do: :ok

  defp submit_prepared({:error, reason}, _opts, _start), do: {:error, reason}

  defp submit_prepared({:ok, preparation}, opts, start) do
    case capture_submission(fn ->
           preparation
           |> call_provider(opts)
           |> then(&persist_result(preparation, &1, opts))
         end) do
      {tag, result} when tag in [:return, :database_error] ->
        emit_submit_stop(preparation, result, start)
        result

      {:exception, exception, stacktrace} ->
        emit_submit_stop(preparation, unexpected_exception_result(), start)
        reraise(exception, stacktrace)
    end
  end

  defp capture_submission(fun) do
    {:return, fun.()}
  rescue
    DBConnection.ConnectionError ->
      {:database_error,
       {:error, Error.new(:temporary, :database_unavailable, "outbound database is unavailable")}}

    exception ->
      {:exception, exception, __STACKTRACE__}
  end

  defp unexpected_exception_result do
    {:error,
     Error.new(:temporary, :unexpected_exception, "outbound submission failed unexpectedly")}
  end

  defp prepare_attempt(message_id, start) do
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

      recipients =
        OutboundRecipient
        |> where([recipient], recipient.outbound_message_id == ^message_id)
        |> order_by([recipient], asc: recipient.kind, asc: recipient.position)
        |> lock("FOR UPDATE")
        |> Repo.all()

      prepare_locked(message, submission, recipients)
    end)
    |> case do
      {:ok, {:ready, message, submission, recipients}} ->
        {:ok,
         %{
           message_id: message.id,
           message: message,
           submission: submission,
           recipients: recipients,
           submission_id: submission.id,
           attempt_count: submission.attempt_count
         }}

      {:ok, {:marked_uncertain, error, message, submission}} ->
        emit_submit_stop(telemetry_context(message, submission), {:error, error}, start)
        {:error, error}

      {:ok, :already_accepted} ->
        {:ok, :already_accepted}

      {:ok, {:error, %Error{} = error}} ->
        {:error, error}

      {:error, reason} ->
        {:error, database_error(reason)}
    end
  end

  defp prepare_locked(nil, _submission, _recipients),
    do: {:error, Error.new(:permanent, :outbound_not_found, "outbound message not found")}

  defp prepare_locked(_message, nil, _recipients),
    do: {:error, Error.new(:permanent, :submission_not_found, "provider submission not found")}

  defp prepare_locked(%OutboundMessage{state: "accepted_by_provider"}, _submission, _recipients),
    do: :already_accepted

  defp prepare_locked(%OutboundMessage{state: "submission_uncertain"}, _submission, _recipients) do
    {:error, Error.new(:permanent, :submission_uncertain, "submission is uncertain")}
  end

  defp prepare_locked(%OutboundMessage{state: "failed"}, _submission, _recipients) do
    {:error, Error.new(:permanent, :submission_not_retryable, "submission is not retryable")}
  end

  defp prepare_locked(
         %OutboundMessage{state: "submitting"} = message,
         %{provider: provider} = submission,
         _recipients
       )
       when provider in ["gmail", "smtp"] do
    mark_uncertain(
      message,
      submission,
      DateTime.utc_now(),
      "interrupted_submission",
      "provider acceptance is ambiguous after an interrupted submission"
    )
  end

  defp prepare_locked(message, submission, recipients) do
    now = DateTime.utc_now()

    if submission.provider == "resend" and submission.attempt_count > 0 and
         DateTime.compare(now, submission.idempotency_expires_at) != :lt do
      mark_uncertain(
        message,
        submission,
        now,
        "idempotency_expired",
        "provider acceptance is ambiguous after idempotency expiry"
      )
    else
      start_attempt(message, submission, recipients, now)
    end
  end

  defp start_attempt(message, submission, recipients, now) do
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
      {:ready, message, submission, recipients}
    end
  end

  defp mark_uncertain(message, submission, now, code, message_text) do
    message
    |> Ecto.Changeset.change(
      state: "submission_uncertain",
      last_error_class: "uncertain",
      last_error_code: code,
      last_error_message: message_text
    )
    |> Repo.update!()

    submission
    |> Ecto.Changeset.change(
      state: "uncertain",
      last_error_code: code,
      last_error_message: message_text
    )
    |> Repo.update!()

    insert_event!(message.id, "submission_uncertain", %{code: code}, now)

    {:marked_uncertain,
     Error.new(:permanent, :submission_uncertain, "submission was not retried"), message,
     submission}
  end

  defp call_provider(:already_accepted, _opts), do: :already_accepted

  defp call_provider(preparation, opts) do
    result =
      with {:ok, provider, config, request, method} <- dispatch(preparation, opts) do
        provider.submit(config, request)
        |> maybe_mark_gmail_reconnect(method, opts)
      end

    maybe_before_persist(opts, preparation, result)

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

  defp dispatch(%{submission: %{provider: "resend", send_method_id: nil}} = preparation, opts) do
    with {:ok, provider} <- provider_adapter("resend", opts) do
      envelope = envelope(preparation.message, preparation.submission, preparation.recipients)

      request = %Request{
        provider: "resend",
        send_method_id: nil,
        envelope: envelope,
        raw_message: "",
        request_sha256: preparation.submission.request_sha256
      }

      {:ok, provider, legacy_resend_config(opts), request, nil}
    end
  end

  defp dispatch(
         %{submission: %{provider: provider, send_method_id: method_id}} = preparation,
         opts
       )
       when provider in ["gmail", "smtp"] and is_binary(method_id) do
    with {:ok, request} <- request(preparation, provider, method_id),
         {:ok, method} <-
           Connectors.checkout_send_method(
             method_id,
             preparation.message.sender_address,
             Keyword.get(opts, :checkout_opts, [])
           ),
         :ok <- require_provider(method, provider),
         {:ok, adapter} <- provider_adapter(provider, opts) do
      {:ok, adapter, provider_config(method, provider, opts), request, method}
    else
      {:error, %Provider.Error{} = error} -> {:error, error}
      {:error, %ConnectorProviderError{} = error} -> {:error, connector_provider_error(error)}
      {:error, %Error{} = error} -> {:error, connector_error(error)}
      {:error, %Ecto.Changeset{}} -> {:error, provider_error("send_method_required")}
      :error -> {:error, provider_error("unsupported_provider")}
    end
  end

  defp dispatch(_preparation, _opts),
    do: {:error, provider_error("send_method_required")}

  defp request(preparation, provider, method_id) do
    envelope = envelope(preparation.message, preparation.submission, preparation.recipients)

    with {:ok, raw_message} <-
           RfcMessage.render(envelope,
             provider: String.to_existing_atom(provider),
             message_id: preparation.submission.provider_rfc_message_id,
             date: preparation.message.queued_at
           ),
         request_sha256 <- sha256(raw_message),
         true <- request_sha256 == preparation.submission.request_sha256 do
      {:ok,
       %Request{
         provider: provider,
         send_method_id: method_id,
         envelope: envelope,
         raw_message: raw_message,
         request_sha256: request_sha256
       }}
    else
      false -> {:error, provider_error("request_integrity_failed")}
      {:error, %Error{}} -> {:error, provider_error("request_integrity_failed")}
    end
  end

  defp require_provider(%SubmissionMethod{kind: provider}, provider), do: :ok

  defp require_provider(%SubmissionMethod{}, _provider),
    do: {:error, provider_error("send_method_provider_mismatch")}

  defp provider_adapter(provider, opts) do
    case Keyword.get(opts, :provider) do
      adapter when is_atom(adapter) and not is_nil(adapter) ->
        {:ok, adapter}

      nil when provider == "resend" ->
        {:ok,
         Application.get_env(
           :manifold_outbound,
           :provider_adapter,
           Manifold.Outbound.Provider.Resend
         )}

      nil ->
        Provider.adapter(provider)
    end
  end

  defp provider_config(%SubmissionMethod{} = method, "gmail", opts) do
    config = if is_list(method.config), do: method.config, else: []
    {:oauth, access_token} = method.credential

    config
    |> Keyword.merge(Keyword.get(opts, :provider_config, []))
    |> Keyword.put(:access_token, access_token)
  end

  defp provider_config(%SubmissionMethod{} = method, "smtp", opts) do
    opts
    |> Keyword.get(:provider_config, [])
    |> Keyword.put(:submission_method, method)
  end

  defp legacy_resend_config(opts) do
    Keyword.get(
      opts,
      :provider_config,
      Application.get_env(:manifold_outbound, :provider_config, [])
    )
  end

  defp connector_error(%Error{} = error) do
    %Provider.Error{
      class: if(error.class == :temporary, do: :transient, else: :permanent),
      code: Atom.to_string(error.reason),
      message: error.message
    }
  end

  defp connector_provider_error(%ConnectorProviderError{} = error) do
    class =
      case error.class do
        :temporary -> :transient
        :uncertain -> :uncertain
        class when class in [:permanent, :reconnect] -> :permanent
      end

    %Provider.Error{
      class: class,
      code: connector_error_code(error.code),
      message: error.message,
      retry_after: error.retry_after_seconds
    }
  end

  defp connector_error_code(code) when is_atom(code), do: Atom.to_string(code)
  defp connector_error_code(code) when is_binary(code), do: code
  defp connector_error_code(_code), do: "connector_error"

  defp maybe_mark_gmail_reconnect(
         {:error, %Provider.Error{class: :permanent, code: "reconnect_required"}} = result,
         %SubmissionMethod{id: method_id, kind: "gmail", credential: {:oauth, access_token}},
         opts
       ) do
    case Connectors.mark_gmail_send_reconnect_required(
           method_id,
           access_token,
           Keyword.get(opts, :reconnect_opts, [])
         ) do
      {:ok, _authorization} -> result
      {:error, _sanitized_reason} -> {:error, reconnect_lifecycle_error()}
    end
  end

  defp maybe_mark_gmail_reconnect(result, _method, _opts), do: result

  defp reconnect_lifecycle_error do
    Error.new(
      :temporary,
      :gmail_reconnect_lifecycle_failed,
      "Gmail reconnect state could not be persisted"
    )
  end

  defp maybe_before_persist(opts, preparation, result) do
    case Keyword.get(opts, :before_result_persist) do
      callback when is_function(callback, 2) -> callback.(preparation, result)
      _none -> :ok
    end
  end

  defp provider_error(code) do
    %Provider.Error{class: :permanent, code: code, message: "outbound submission is invalid"}
  end

  defp persist_result(:already_accepted, :already_accepted, _opts), do: :ok

  defp persist_result(_preparation, {:injected_failure, %Error{} = error}, _opts),
    do: {:error, error}

  defp persist_result(_preparation, {:error, %Error{} = error}, _opts), do: {:error, error}

  defp persist_result(preparation, {:error, %Provider.Error{class: :uncertain} = error}, opts) do
    now = DateTime.utc_now()

    result =
      Repo.transaction(fn ->
        {message, submission} = lock_submission!(preparation)
        maybe_fail(opts, :provider_error_commit)

        case result_fence(message, submission, preparation) do
          :current ->
            message
            |> Ecto.Changeset.change(
              state: "submission_uncertain",
              last_error_class: "uncertain",
              last_error_code: error.code,
              last_error_message: error.message
            )
            |> Repo.update!()

            submission
            |> Ecto.Changeset.change(
              state: "uncertain",
              last_http_status: error.http_status,
              last_error_code: error.code,
              last_error_message: error.message
            )
            |> Repo.update!()

            insert_event!(message.id, "submission_uncertain", %{code: error.code}, now)
            :transitioned

          terminal_or_stale ->
            terminal_or_stale
        end
      end)

    case result do
      {:ok, :transitioned} ->
        {:error,
         Error.new(
           :permanent,
           :submission_uncertain,
           "provider acceptance is uncertain; automatic retry is disabled"
         )}

      {:ok, {:terminal, "uncertain"}} ->
        submission_uncertain_error()

      {:ok, terminal_or_stale} ->
        stale_result(terminal_or_stale)

      {:error, reason} ->
        {:error, database_error(reason)}
    end
  end

  defp persist_result(preparation, {:ok, %Provider.Submission{} = provider_submission}, opts) do
    now = DateTime.utc_now()

    result =
      Repo.transaction(fn ->
        {message, submission} = lock_submission!(preparation)
        maybe_fail(opts, :provider_accept_commit)

        case result_fence(message, submission, preparation) do
          :current ->
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

            :accepted

          terminal_or_stale ->
            terminal_or_stale
        end
      end)

    case result do
      {:ok, :accepted} ->
        :ok

      {:ok, {:terminal, "accepted_by_provider"}} ->
        :ok

      {:ok, {:terminal, "uncertain"}} ->
        submission_uncertain_error()

      {:ok, terminal_or_stale} ->
        stale_result(terminal_or_stale)

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

        case result_fence(message, submission, preparation) do
          :current ->
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
            :persisted_error

          terminal_or_stale ->
            terminal_or_stale
        end
      end)

    case result do
      {:ok, :persisted_error} -> {:error, error}
      {:ok, {:terminal, "accepted_by_provider"}} -> :ok
      {:ok, {:terminal, "uncertain"}} -> submission_uncertain_error()
      {:ok, terminal_or_stale} -> stale_result(terminal_or_stale)
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

  defp result_fence(message, submission, preparation) do
    cond do
      message.state == "accepted_by_provider" ->
        {:terminal, "accepted_by_provider"}

      message.state == "submission_uncertain" ->
        {:terminal, "uncertain"}

      message.state == "failed" ->
        {:terminal, "failed"}

      message.state == "submitting" and submission.state == "submitting" and
          submission.attempt_count == preparation.attempt_count ->
        :current

      true ->
        :stale
    end
  end

  defp submission_uncertain_error do
    {:error,
     Error.new(
       :permanent,
       :submission_uncertain,
       "provider acceptance is uncertain; automatic retry is disabled"
     )}
  end

  defp stale_result({:terminal, "failed"}),
    do: {:error, Error.new(:permanent, :submission_not_retryable, "submission failed")}

  defp stale_result(_stale),
    do: {:error, Error.new(:temporary, :stale_submission_result, "stale submission result")}

  defp emit_submit_stop(preparation, result, start) do
    {outcome, error_code} = submit_outcome(result)

    metadata = submit_metadata(preparation, outcome)

    metadata = if error_code, do: Map.put(metadata, :error_code, error_code), else: metadata

    :telemetry.execute(
      [:manifold, :outbound, :submit, :stop],
      %{
        duration_ms:
          System.convert_time_unit(System.monotonic_time() - start, :native, :millisecond),
        attempt_count: preparation.attempt_count
      },
      metadata
    )
  end

  defp submit_outcome(:ok), do: {:accepted, nil}

  defp submit_outcome({:error, %Provider.Error{class: :transient, code: code}}),
    do: {:retryable, telemetry_error_code(code)}

  defp submit_outcome({:error, %Provider.Error{class: :uncertain, code: code}}),
    do: {:uncertain, telemetry_error_code(code)}

  defp submit_outcome({:error, %Provider.Error{code: code}}),
    do: {:failed, telemetry_error_code(code)}

  defp submit_outcome({:error, %Error{reason: :submission_uncertain}}),
    do: {:uncertain, :submission_uncertain}

  defp submit_outcome({:error, %Error{reason: reason}}),
    do: {:error, telemetry_error_code(reason)}

  defp submit_outcome(_result), do: {:error, :submission_failed}

  defp telemetry_error_code(code) when is_atom(code) do
    if MapSet.member?(@telemetry_error_codes, Atom.to_string(code)),
      do: code,
      else: :provider_error
  end

  defp telemetry_error_code(code) when is_binary(code) do
    if MapSet.member?(@telemetry_error_codes, code), do: code, else: "provider_error"
  end

  defp telemetry_error_code(_code), do: :provider_error

  defp submit_metadata(%{message: message, submission: submission} = preparation, outcome) do
    %{
      account_id: message.mailbox_id,
      outbound_message_id: preparation.message_id,
      submission_id: preparation.submission_id,
      send_method_id: submission.send_method_id,
      provider: submission.provider,
      method_kind: submission.provider,
      adapter: submission.provider,
      outcome: outcome
    }
  end

  defp submit_metadata(%{message_id: message_id}, outcome) do
    %{
      account_id: nil,
      outbound_message_id: message_id,
      submission_id: nil,
      send_method_id: nil,
      provider: nil,
      method_kind: nil,
      adapter: nil,
      outcome: outcome
    }
  end

  defp telemetry_context(message, submission) do
    %{
      message_id: message.id,
      message: message,
      submission: submission,
      submission_id: submission.id,
      attempt_count: submission.attempt_count
    }
  end

  defp envelope(message, submission, recipients) do
    %Envelope{
      from: format_address(message.sender_name, message.sender_address),
      to: recipient_addresses(recipients, "to"),
      cc: recipient_addresses(recipients, "cc"),
      bcc: recipient_addresses(recipients, "bcc"),
      subject: message.subject,
      text: message.text_body || "",
      message_id: submission.provider_rfc_message_id,
      queued_at: message.queued_at,
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

  defp sha256(bytes) do
    :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  end

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
