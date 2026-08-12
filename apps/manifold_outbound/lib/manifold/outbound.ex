defmodule Manifold.Outbound do
  @moduledoc """
  Public draft, managed submission, and provider-event context.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias Manifold.Accounts
  alias Manifold.Connectors
  alias Manifold.Core.{Address, Error}
  alias Manifold.Mail
  alias Manifold.Outbound.Composition
  alias Manifold.Outbound.Jobs.SubmitOutbound
  alias Manifold.Outbound.Provider.Envelope
  alias Manifold.Outbound.ProviderEvents
  alias Manifold.Outbound.RfcMessage
  alias Manifold.Outbound.Submission

  alias Manifold.Outbound.Schema.{
    OutboundEvent,
    OutboundMessage,
    OutboundRecipient,
    ProviderEvent,
    ProviderSubmission
  }

  alias Manifold.Outbound.State
  alias Manifold.Outbound.View
  alias Manifold.Repo

  @recipient_kinds ~w(to cc bcc)
  @max_recipients 50
  @telemetry_forbidden_fragments ~w(token password authorization_code raw_message)
  @telemetry_code_pattern ~r/\A[a-z0-9_.:-]{1,128}\z/

  @spec create_draft(Ecto.UUID.t(), map()) ::
          {:ok, OutboundMessage.t()} | {:error, Error.t() | Ecto.Changeset.t()}
  def create_draft(mailbox_id, attrs), do: create_draft(mailbox_id, attrs, [])

  @doc false
  @spec create_draft(Ecto.UUID.t(), map(), Keyword.t()) ::
          {:ok, OutboundMessage.t()} | {:error, Error.t() | Ecto.Changeset.t()}
  def create_draft(mailbox_id, attrs, opts) do
    with {:ok, _identity} <- Accounts.get_sender_identity(mailbox_id),
         {:ok, recipients} <- normalize_recipients(Map.get(attrs, :recipients, [])) do
      run_before_persist(opts)
      now = DateTime.utc_now()

      Repo.transaction(fn ->
        case lock_active_sender(Repo, mailbox_id) do
          {:ok, mailbox} ->
            sender_address = Accounts.account_address(mailbox)

            message_attrs = %{
              mailbox_id: mailbox_id,
              state: "draft",
              composition_kind: Map.get(attrs, :composition_kind, "new"),
              source_message_id: Map.get(attrs, :source_message_id),
              sender_name: mailbox.name,
              sender_address: sender_address,
              canonical_sender_address: String.downcase(sender_address, :ascii),
              subject: Map.get(attrs, :subject),
              text_body: Map.get(attrs, :text_body),
              in_reply_to: Map.get(attrs, :in_reply_to),
              references: Map.get(attrs, :references, [])
            }

            case %OutboundMessage{}
                 |> OutboundMessage.create_changeset(message_attrs)
                 |> Repo.insert() do
              {:ok, message} ->
                insert_recipients!(message.id, recipients, now)
                insert_event!(message.id, "draft_created", now)
                message

              {:error, changeset} ->
                Repo.rollback(changeset)
            end

          {:error, reason} ->
            Repo.rollback(reason)
        end
      end)
      |> normalize_transaction()
    end
  rescue
    DBConnection.ConnectionError -> {:error, database_error(:unavailable)}
  end

  @spec list_recipients(Ecto.UUID.t()) :: [OutboundRecipient.t()]
  def list_recipients(outbound_message_id) do
    OutboundRecipient
    |> where([recipient], recipient.outbound_message_id == ^outbound_message_id)
    |> order_by(
      [recipient],
      asc:
        fragment(
          "CASE ? WHEN 'to' THEN 0 WHEN 'cc' THEN 1 ELSE 2 END",
          recipient.kind
        ),
      asc: recipient.position
    )
    |> Repo.all()
  end

  @spec update_draft(Ecto.UUID.t(), Ecto.UUID.t(), map(), Keyword.t()) ::
          {:ok, OutboundMessage.t()} | {:error, Error.t() | Ecto.Changeset.t()}
  def update_draft(mailbox_id, draft_id, attrs, opts \\ []) do
    with {:ok, recipients} <- normalize_optional_recipients(attrs) do
      case Repo.get_by(OutboundMessage, id: draft_id, mailbox_id: mailbox_id) do
        nil ->
          {:error, error(:permanent, :draft_not_found, "draft not found in mailbox")}

        %OutboundMessage{state: state} when state != "draft" ->
          {:error, error(:permanent, :message_not_editable, "outbound message is not editable")}

        %OutboundMessage{} = draft ->
          with :ok <- expected_revision(draft, opts) do
            run_before_persist(opts)

            update_draft_transaction(
              mailbox_id,
              draft,
              Map.delete(attrs, :recipients),
              recipients
            )
          end
      end
    end
  rescue
    DBConnection.ConnectionError -> {:error, database_error(:unavailable)}
  end

  @spec list_drafts(Ecto.UUID.t()) :: [View.DraftSummary.t()]
  def list_drafts(mailbox_id) do
    from(message in OutboundMessage,
      left_join: recipient in OutboundRecipient,
      on: recipient.outbound_message_id == message.id,
      where: message.mailbox_id == ^mailbox_id and message.state == "draft",
      group_by: message.id,
      order_by: [desc: message.updated_at, desc: message.id],
      select: {message, count(recipient.id)}
    )
    |> Repo.all()
    |> Enum.map(fn {message, recipient_count} ->
      %View.DraftSummary{
        id: message.id,
        subject: message.subject || "(No subject)",
        preview: body_preview(message.text_body),
        recipient_count: recipient_count,
        updated_at: message.updated_at
      }
    end)
  end

  @spec get_draft(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, View.Draft.t()} | {:error, Error.t()}
  def get_draft(mailbox_id, draft_id) do
    case Repo.get_by(OutboundMessage, id: draft_id, mailbox_id: mailbox_id, state: "draft") do
      %OutboundMessage{} = draft ->
        {:ok, draft_view(draft)}

      nil ->
        {:error, error(:permanent, :draft_not_found, "draft not found in mailbox")}
    end
  rescue
    DBConnection.ConnectionError -> {:error, database_error(:unavailable)}
  end

  @spec prepare_draft(Ecto.UUID.t(), Ecto.UUID.t(), :reply | :reply_all | :forward) ::
          {:ok, OutboundMessage.t()} | {:error, Error.t() | Ecto.Changeset.t()}
  def prepare_draft(mailbox_id, message_id, kind) do
    with {:ok, identity} <- Accounts.get_sender_identity(mailbox_id),
         {:ok, source} <- Mail.get_reply_source(mailbox_id, message_id),
         {:ok, prepared} <- Composition.prepare(kind, Map.from_struct(source), identity.address) do
      create_draft(mailbox_id, prepared_to_attrs(prepared))
    end
  end

  @spec delete_draft(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, OutboundMessage.t()} | {:error, Error.t() | Ecto.Changeset.t()}
  def delete_draft(mailbox_id, draft_id) do
    case Repo.get_by(OutboundMessage, id: draft_id, mailbox_id: mailbox_id, state: "draft") do
      %OutboundMessage{} = draft -> Repo.delete(draft)
      nil -> {:error, error(:permanent, :draft_not_found, "draft not found in mailbox")}
    end
  rescue
    DBConnection.ConnectionError -> {:error, database_error(:unavailable)}
  end

  @spec list_sent(Ecto.UUID.t()) :: [View.SentSummary.t()]
  def list_sent(mailbox_id) do
    messages =
      OutboundMessage
      |> where([message], message.mailbox_id == ^mailbox_id and message.state != "draft")
      |> order_by(
        [message],
        desc: fragment("COALESCE(?, ?)", message.queued_at, message.updated_at),
        desc: message.id
      )
      |> Repo.all()

    recipients_by_message =
      OutboundRecipient
      |> where([recipient], recipient.outbound_message_id in ^Enum.map(messages, & &1.id))
      |> order_by([recipient], asc: recipient.kind, asc: recipient.position)
      |> Repo.all()
      |> Enum.group_by(& &1.outbound_message_id)

    Enum.map(messages, fn message ->
      %View.SentSummary{
        id: message.id,
        subject: message.subject || "(No subject)",
        state: message.state,
        recipients:
          recipients_by_message
          |> Map.get(message.id, [])
          |> Enum.map(& &1.canonical_address),
        queued_at: message.queued_at,
        updated_at: message.updated_at
      }
    end)
  end

  @spec get_sent(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, View.SentDetail.t()} | {:error, Error.t()}
  def get_sent(mailbox_id, outbound_message_id) do
    message =
      OutboundMessage
      |> where(
        [message],
        message.id == ^outbound_message_id and message.mailbox_id == ^mailbox_id and
          message.state != "draft"
      )
      |> Repo.one()

    case message do
      %OutboundMessage{} = message ->
        submission =
          Repo.get_by(ProviderSubmission, outbound_message_id: outbound_message_id)

        events =
          OutboundEvent
          |> where([event], event.outbound_message_id == ^outbound_message_id)
          |> order_by([event], asc: event.occurred_at, asc: event.id)
          |> Repo.all()

        {:ok, sent_detail_view(message, submission, events)}

      nil ->
        {:error, error(:permanent, :sent_not_found, "sent message not found in mailbox")}
    end
  rescue
    DBConnection.ConnectionError -> {:error, database_error(:unavailable)}
  end

  @spec queue_draft(Ecto.UUID.t(), Ecto.UUID.t(), Keyword.t()) ::
          {:ok, OutboundMessage.t()} | {:error, Error.t() | Ecto.Changeset.t()}
  def queue_draft(mailbox_id, draft_id, opts \\ []) do
    start = System.monotonic_time()
    now = DateTime.utc_now()

    multi =
      Multi.new()
      |> Multi.run(:sender, fn repo, _changes ->
        lock_active_sender(repo, mailbox_id)
      end)
      |> Multi.run(:draft, fn repo, _changes ->
        draft =
          OutboundMessage
          |> where([message], message.id == ^draft_id and message.mailbox_id == ^mailbox_id)
          |> lock("FOR UPDATE")
          |> repo.one()

        case draft do
          nil ->
            {:error, error(:permanent, :draft_not_found, "draft not found in mailbox")}

          %OutboundMessage{state: state} when state != "draft" ->
            {:ok, {draft, false}}

          %OutboundMessage{} = draft ->
            with :ok <- expected_revision(draft, opts) do
              {:ok, {draft, true}}
            end
        end
      end)
      |> Multi.run(:recipients, fn repo, %{draft: {draft, queue?}} ->
        if queue? do
          recipients =
            OutboundRecipient
            |> where([recipient], recipient.outbound_message_id == ^draft.id)
            |> order_by([recipient], asc: recipient.kind, asc: recipient.position)
            |> lock("FOR UPDATE")
            |> repo.all()

          with :ok <- validate_queueable(draft, recipients) do
            {:ok, recipients}
          end
        else
          {:ok, []}
        end
      end)
      |> Multi.run(:send_method, fn _repo, %{draft: {draft, queue?}} ->
        if queue? do
          with {:ok, method} <- Connectors.enabled_send_method(draft.mailbox_id),
               :ok <- validate_sender(draft, method) do
            {:ok, method}
          end
        else
          {:ok, nil}
        end
      end)
      |> Multi.run(:rendered, fn _repo,
                                 %{
                                   draft: {draft, queue?},
                                   recipients: recipients,
                                   send_method: method
                                 } ->
        if queue? do
          render_submission(draft, recipients, method, now)
        else
          {:ok, nil}
        end
      end)
      |> Multi.run(:queued, fn repo, %{draft: {draft, queue?}} ->
        if queue? do
          draft
          |> OutboundMessage.queue_changeset(now)
          |> repo.update()
        else
          {:ok, draft}
        end
      end)
      |> Multi.run(:submission, fn repo,
                                   %{
                                     draft: {_draft, queue?},
                                     queued: queued,
                                     rendered: rendered
                                   } ->
        if queue? do
          rendered
          |> submission_changeset(queued)
          |> repo.insert(log: false, telemetry_event: nil)
        else
          {:ok, repo.get_by(ProviderSubmission, outbound_message_id: queued.id)}
        end
      end)
      |> Multi.run(:queued_event, fn repo, %{draft: {_draft, queue?}, queued: queued} ->
        if queue? do
          queued.id
          |> event_changeset("queued", now)
          |> repo.insert()
        else
          {:ok, nil}
        end
      end)
      |> Multi.run(:fault_boundary, fn _repo, %{draft: {_draft, queue?}} ->
        if queue? and Keyword.get(opts, :fail_at) == :after_queue_before_job do
          {:error, error(:temporary, :after_queue_before_job, "injected outbound failure")}
        else
          {:ok, :ok}
        end
      end)
      |> Multi.run(:job, fn repo, %{draft: {_draft, queue?}, queued: queued} ->
        if queue? do
          queued.id
          |> then(&SubmitOutbound.new(%{outbound_message_id: &1}))
          |> repo.insert()
        else
          {:ok, nil}
        end
      end)

    case Repo.transaction(multi) do
      {:ok, %{queued: queued}} ->
        {:ok, queued}

      {:error, :send_method, reason, %{draft: {%OutboundMessage{} = draft, true}}} ->
        emit_send_method_selection_failure(draft, reason, start)
        {:error, reason}

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  rescue
    DBConnection.ConnectionError -> {:error, database_error(:unavailable)}
  end

  @spec submit_message(Ecto.UUID.t(), Keyword.t()) ::
          :ok | {:error, Error.t() | Manifold.Outbound.Provider.Error.t()}
  def submit_message(message_id, opts \\ []), do: Submission.submit(message_id, opts)

  @spec record_provider_event(String.t(), Manifold.Outbound.Provider.Event.t(), Keyword.t()) ::
          {:ok, :processed | :unmatched | :duplicate}
          | {:error, Error.t() | Ecto.Changeset.t()}
  def record_provider_event(provider, event, opts \\ []) do
    ProviderEvents.record(provider, event, opts)
  end

  @doc false
  @spec cancel_account_jobs(Ecto.UUID.t(), pos_integer()) ::
          {:snooze, 5} | %{cancelled: non_neg_integer(), done?: boolean()}
  def cancel_account_jobs(mailbox_id, limit) when is_integer(limit) and limit > 0 do
    {:ok, result} =
      Repo.transaction(fn ->
        matching = account_job_query(mailbox_id)

        selected =
          matching
          |> order_by([job], asc: job.id)
          |> limit(^limit)
          |> lock("FOR UPDATE SKIP LOCKED")
          |> select([job], {job.id, job.state})
          |> Repo.all()

        selected_ids = Enum.map(selected, &elem(&1, 0))
        selected_executing? = Enum.any?(selected, &(elem(&1, 1) == "executing"))

        cancelled =
          case selected_ids do
            [] ->
              0

            ids ->
              {:ok, count} =
                Oban.Job
                |> where([job], job.id in ^ids)
                |> Oban.cancel_all_jobs()

              count
          end

        matching_executing? =
          matching
          |> where([job], job.state == "executing")
          |> Repo.exists?()

        if selected_executing? or matching_executing? do
          {:snooze, 5}
        else
          %{cancelled: cancelled, done?: not Repo.exists?(matching)}
        end
      end)

    result
  end

  @doc false
  @spec purge_account_batch(Ecto.UUID.t(), pos_integer()) :: %{
          deleted: non_neg_integer(),
          done?: boolean()
        }
  def purge_account_batch(mailbox_id, limit) when is_integer(limit) and limit > 0 do
    {:ok, result} =
      Repo.transaction(fn ->
        message_ids =
          OutboundMessage
          |> where([message], message.mailbox_id == ^mailbox_id)
          |> order_by([message], asc: message.id)
          |> limit(^limit)
          |> lock("FOR UPDATE SKIP LOCKED")
          |> select([message], message.id)
          |> Repo.all()

        ProviderEvent
        |> where([event], event.outbound_message_id in ^message_ids)
        |> Repo.delete_all()

        {deleted, _rows} =
          OutboundMessage
          |> where([message], message.id in ^message_ids and message.mailbox_id == ^mailbox_id)
          |> Repo.delete_all()

        %{deleted: deleted, done?: not account_data_remaining?(Repo, mailbox_id)}
      end)

    result
  end

  @spec account_data_remaining?(Ecto.UUID.t()) :: boolean()
  def account_data_remaining?(mailbox_id), do: account_data_remaining?(Repo, mailbox_id)

  defp normalize_recipients(recipients)
       when is_list(recipients) and length(recipients) <= @max_recipients do
    recipients
    |> Enum.reduce_while({:ok, [], MapSet.new(), %{}}, fn recipient,
                                                          {:ok, rows, seen, positions} ->
      kind = Map.get(recipient, :kind)
      address = Map.get(recipient, :address)

      case normalize_recipient(kind, address, seen) do
        {:ok, parsed} ->
          position = Map.get(positions, kind, 0)

          row = %{
            kind: kind,
            position: position,
            display_name: Map.get(recipient, :display_name),
            address: address,
            canonical_address: parsed.canonical
          }

          {:cont,
           {:ok, [row | rows], MapSet.put(seen, parsed.canonical),
            Map.put(positions, kind, position + 1)}}

        {:error, %Error{}} = failure ->
          {:halt, failure}
      end
    end)
    |> case do
      {:ok, rows, _seen, _positions} -> {:ok, Enum.reverse(rows)}
      {:error, %Error{}} = failure -> failure
    end
  end

  defp normalize_recipients(_recipients) do
    {:error, error(:permanent, :invalid_recipient, "invalid recipient list")}
  end

  defp normalize_optional_recipients(attrs) do
    case Map.fetch(attrs, :recipients) do
      {:ok, recipients} -> normalize_recipients(recipients)
      :error -> {:ok, nil}
    end
  end

  defp normalize_recipient(kind, address, seen) when kind in @recipient_kinds do
    case Address.parse(address) do
      {:ok, parsed} ->
        if MapSet.member?(seen, parsed.canonical) do
          {:error, error(:permanent, :duplicate_recipient, "duplicate recipient")}
        else
          {:ok, parsed}
        end

      {:error, _error} ->
        {:error, error(:permanent, :invalid_recipient, "invalid recipient address")}
    end
  end

  defp normalize_recipient(_kind, _address, _seen) do
    {:error, error(:permanent, :invalid_recipient, "invalid recipient address")}
  end

  defp insert_recipients!(message_id, recipients, now) do
    rows =
      Enum.map(recipients, fn recipient ->
        recipient
        |> Map.put(:id, Ecto.UUID.generate())
        |> Map.put(:outbound_message_id, message_id)
        |> Map.put(:inserted_at, now)
        |> Map.put(:updated_at, now)
      end)

    Repo.insert_all(OutboundRecipient, rows)
  end

  defp draft_view(draft) do
    %View.Draft{
      id: draft.id,
      composition_kind: draft.composition_kind,
      source_message_id: draft.source_message_id,
      sender_address: draft.sender_address,
      subject: draft.subject,
      text_body: draft.text_body,
      in_reply_to: draft.in_reply_to,
      references: draft.references,
      recipients: Enum.map(list_recipients(draft.id), &recipient_view/1),
      lock_version: draft.lock_version,
      updated_at: draft.updated_at
    }
  end

  defp sent_detail_view(message, submission, events) do
    %View.SentDetail{
      id: message.id,
      state: message.state,
      sender_address: message.sender_address,
      subject: message.subject || "(No subject)",
      text_body: message.text_body,
      recipients: Enum.map(list_recipients(message.id), &recipient_view/1),
      submission: submission_view(submission),
      events: Enum.map(events, &event_view/1),
      queued_at: message.queued_at,
      accepted_at: message.accepted_at,
      last_error_class: message.last_error_class,
      last_error_code: message.last_error_code,
      last_error_message: message.last_error_message,
      updated_at: message.updated_at
    }
  end

  defp recipient_view(recipient) do
    %View.Recipient{
      kind: recipient.kind,
      position: recipient.position,
      display_name: recipient.display_name,
      address: recipient.address,
      canonical_address: recipient.canonical_address,
      delivery_state: recipient.delivery_state,
      last_event_at: recipient.last_event_at,
      status_detail: recipient.status_detail
    }
  end

  defp body_preview(nil), do: ""

  defp body_preview(body) do
    body
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.slice(0, 160)
  end

  defp submission_view(nil), do: nil

  defp submission_view(submission) do
    %View.Submission{
      provider: submission.provider,
      state: submission.state,
      attempt_count: submission.attempt_count,
      provider_message_id: submission.provider_message_id,
      accepted_at: submission.accepted_at,
      last_http_status: submission.last_http_status,
      last_error_code: submission.last_error_code,
      last_error_message: submission.last_error_message
    }
  end

  defp event_view(event) do
    %View.Event{
      event_type: event.event_type,
      metadata: event.metadata,
      occurred_at: event.occurred_at
    }
  end

  defp prepared_to_attrs(prepared) do
    recipients =
      for {kind, addresses} <- [
            {"to", prepared.to},
            {"cc", prepared.cc},
            {"bcc", prepared.bcc}
          ],
          address <- addresses do
        %{
          kind: kind,
          address: address.address,
          display_name: Map.get(address, :display_name)
        }
      end

    prepared
    |> Map.take([
      :composition_kind,
      :source_message_id,
      :subject,
      :text_body,
      :in_reply_to,
      :references
    ])
    |> Map.put(:recipients, recipients)
  end

  defp update_draft_transaction(mailbox_id, draft, attrs, recipients) do
    Repo.transaction(fn ->
      case lock_active_sender(Repo, mailbox_id) do
        {:ok, _mailbox} ->
          case draft
               |> OutboundMessage.draft_changeset(attrs)
               |> Repo.update(stale_error_field: :lock_version) do
            {:ok, updated} ->
              if is_list(recipients) do
                OutboundRecipient
                |> where([recipient], recipient.outbound_message_id == ^updated.id)
                |> Repo.delete_all()

                insert_recipients!(updated.id, recipients, DateTime.utc_now())
              end

              updated

            {:error, changeset} ->
              Repo.rollback(changeset)
          end

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
    |> normalize_transaction()
    |> normalize_stale()
  end

  defp submission_changeset(rendered, message) do
    %ProviderSubmission{}
    |> ProviderSubmission.changeset(%{
      outbound_message_id: message.id,
      send_method_id: rendered.send_method_id,
      provider: rendered.provider,
      canonical_sender_address: rendered.canonical_sender_address,
      idempotency_key: rendered.idempotency_key,
      request_sha256: rendered.request_sha256,
      request_payload: rendered.request_payload,
      render_version: rendered.render_version,
      provider_rfc_message_id: rendered.provider_rfc_message_id,
      state: "pending",
      attempt_count: 0,
      idempotency_expires_at: nil
    })
  end

  defp render_submission(message, recipients, method, now) do
    provider_rfc_message_id = "<#{message.id}@manifold.local>"
    idempotency_key = Ecto.UUID.generate()

    envelope = %Envelope{
      from: mailbox(message.sender_name, message.sender_address),
      to: recipient_mailboxes(recipients, "to"),
      cc: recipient_mailboxes(recipients, "cc"),
      bcc: recipient_mailboxes(recipients, "bcc"),
      subject: message.subject,
      text: message.text_body || "",
      message_id: provider_rfc_message_id,
      queued_at: now,
      in_reply_to: message.in_reply_to,
      references: message.references,
      idempotency_key: idempotency_key
    }

    with {:ok, provider} <- provider(method.kind),
         {:ok, raw_message} <-
           RfcMessage.render(envelope,
             provider: provider,
             message_id: provider_rfc_message_id,
             date: now
           ) do
      {:ok,
       %{
         send_method_id: method.id,
         provider: method.kind,
         provider_rfc_message_id: provider_rfc_message_id,
         idempotency_key: idempotency_key,
         canonical_sender_address: message.canonical_sender_address,
         render_version: 1,
         request_payload: raw_message,
         request_sha256: sha256(raw_message)
       }}
    end
  end

  defp provider("gmail"), do: {:ok, :gmail}
  defp provider("smtp"), do: {:ok, :smtp}
  defp provider("microsoft"), do: {:ok, :microsoft}

  defp provider(_kind),
    do: {:error, error(:permanent, :send_method_required, "an enabled send method is required")}

  defp emit_send_method_selection_failure(draft, reason, start) do
    :telemetry.execute(
      [:manifold, :outbound, :send_method, :select, :stop],
      %{
        duration_ms:
          System.convert_time_unit(System.monotonic_time() - start, :native, :millisecond),
        attempt_count: 1
      },
      %{
        account_id: draft.mailbox_id,
        outbound_message_id: draft.id,
        outcome: :error,
        error_code: telemetry_error_code(reason)
      }
    )
  end

  defp telemetry_error_code(%Error{reason: reason}), do: telemetry_error_code(reason)
  defp telemetry_error_code(%Ecto.Changeset{}), do: :send_method_selection_failed

  defp telemetry_error_code(code) when is_atom(code) do
    if safe_telemetry_code?(Atom.to_string(code)), do: code, else: :send_method_selection_failed
  end

  defp telemetry_error_code(code) when is_binary(code) do
    if safe_telemetry_code?(code), do: code, else: "send_method_selection_failed"
  end

  defp telemetry_error_code(_reason), do: :send_method_selection_failed

  defp safe_telemetry_code?(code) do
    downcased = String.downcase(code)

    Regex.match?(@telemetry_code_pattern, downcased) and
      not Enum.any?(@telemetry_forbidden_fragments, &String.contains?(downcased, &1))
  end

  defp validate_sender(draft, method) do
    with true <- method.account_id == draft.mailbox_id,
         {:ok, draft_address} <- Address.parse(draft.sender_address),
         {:ok, method_address} <- Address.parse(method.email_address),
         true <- draft_address.canonical == draft.canonical_sender_address,
         true <- method_address.canonical == draft.canonical_sender_address do
      :ok
    else
      _mismatch ->
        {:error,
         error(
           :permanent,
           :sender_address_mismatch,
           "send method sender does not match draft sender"
         )}
    end
  end

  defp recipient_mailboxes(recipients, kind) do
    recipients
    |> Enum.filter(&(&1.kind == kind))
    |> Enum.map(&mailbox(&1.display_name, &1.address))
  end

  defp mailbox(nil, address), do: address
  defp mailbox("", address), do: address
  defp mailbox(display_name, address), do: "#{display_name} <#{address}>"

  defp sha256(bytes) do
    bytes
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp insert_event!(message_id, event_type, now) do
    message_id
    |> event_changeset(event_type, now)
    |> Repo.insert!()
  end

  defp event_changeset(message_id, event_type, now) do
    OutboundEvent.changeset(%OutboundEvent{}, %{
      outbound_message_id: message_id,
      event_type: event_type,
      occurred_at: now
    })
  end

  defp expected_revision(draft, opts) do
    case Keyword.fetch(opts, :expected_revision) do
      {:ok, revision} when revision == draft.lock_version ->
        :ok

      {:ok, _revision} ->
        {:error, error(:permanent, :stale_draft, "draft was changed by another session")}

      :error ->
        :ok
    end
  end

  defp validate_queueable(draft, recipients) do
    cond do
      recipients == [] ->
        {:error, error(:permanent, :missing_recipient, "at least one recipient is required")}

      not Enum.any?(recipients, &(&1.kind == "to")) ->
        {:error, error(:permanent, :missing_recipient, "at least one To recipient is required")}

      is_nil(draft.subject) or String.trim(draft.subject) == "" ->
        {:error, error(:permanent, :missing_subject, "subject is required")}

      true ->
        State.validate_transition(draft.state, "queued")
    end
  end

  defp account_job_query(mailbox_id) do
    Oban.Job
    |> where(
      [job],
      job.worker == ^inspect(SubmitOutbound) and
        job.state in ~w(available scheduled executing retryable suspended)
    )
    |> where(
      [job],
      fragment(
        """
        EXISTS (
          SELECT 1
          FROM "outbound_messages" AS outbound_message
          WHERE outbound_message.mailbox_id = ?
            AND outbound_message.id = CASE
              WHEN (?->>'outbound_message_id') ~*
                '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
              THEN (?->>'outbound_message_id')::uuid
              ELSE NULL
            END
        )
        """,
        type(^mailbox_id, :binary_id),
        job.args,
        job.args
      )
    )
  end

  defp lock_active_sender(repo, mailbox_id) do
    case Accounts.active_account_for_update(repo, mailbox_id) do
      {:ok, %{domain: %{active: true}} = mailbox} -> {:ok, mailbox}
      {:ok, _mailbox} -> {:error, sender_not_active_error()}
      {:error, %Error{reason: :mailbox_not_active}} -> {:error, sender_not_active_error()}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp sender_not_active_error do
    error(:permanent, :sender_not_active, "sender account is not active")
  end

  defp account_data_remaining?(repo, mailbox_id) do
    repo.exists?(where(OutboundMessage, [message], message.mailbox_id == ^mailbox_id))
  end

  defp run_before_persist(opts) do
    case Keyword.get(opts, :before_persist) do
      callback when is_function(callback, 0) -> callback.()
      nil -> :ok
    end

    :ok
  end

  defp normalize_transaction({:ok, value}), do: {:ok, value}
  defp normalize_transaction({:error, reason}), do: {:error, reason}

  defp normalize_stale({:error, %Ecto.Changeset{} = changeset} = failure) do
    case Keyword.get(changeset.errors, :lock_version) do
      {_message, options} ->
        if Keyword.get(options, :stale, false) do
          {:error, error(:permanent, :stale_draft, "draft was changed by another session")}
        else
          failure
        end

      nil ->
        failure
    end
  end

  defp normalize_stale(result), do: result

  defp database_error(reason),
    do:
      error(:temporary, :database_unavailable, "outbound database operation failed", %{
        reason: inspect(reason)
      })

  defp error(class, reason, message, details \\ %{}),
    do: Error.new(class, reason, message, details)
end
