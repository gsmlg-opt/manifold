defmodule Manifold.Mail do
  @moduledoc """
  Public mailbox projection and webmail context.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias Manifold.Core.Error
  alias Manifold.Mail.Schema.{Attachment, MailboxEntry, Message}
  alias Manifold.Repo

  alias Manifold.Mail.{
    Acceptance,
    ExternalState,
    InboundSource,
    Mailbox,
    ProjectionResult,
    Projector,
    ReceivedAt
  }

  @spec add_acceptance_entries(
          Multi.t(),
          atom(),
          atom(),
          [map() | struct()],
          DateTime.t()
        ) :: Multi.t()
  def add_acceptance_entries(multi, step_name, delivery_step, routes, now) do
    Acceptance.add_entries(multi, step_name, delivery_step, routes, now)
  end

  @spec add_external_acceptance_entry(
          Multi.t(),
          atom(),
          atom(),
          Ecto.UUID.t(),
          String.t(),
          DateTime.t()
        ) :: Multi.t()
  def add_external_acceptance_entry(
        multi,
        step_name,
        delivery_step,
        mailbox_id,
        recipient_address,
        now
      ) do
    Acceptance.add_external_entry(
      multi,
      step_name,
      delivery_step,
      mailbox_id,
      recipient_address,
      now
    )
  end

  @spec project_inbound(InboundSource.t(), Keyword.t()) ::
          {:ok, ProjectionResult.t()} | {:error, Error.t()}
  def project_inbound(source, opts \\ []), do: Projector.project(source, opts)

  @spec apply_external_state(
          Ecto.UUID.t(),
          Ecto.UUID.t(),
          ExternalState.normalized_state()
        ) :: {:ok, :applied} | {:error, Error.t()}
  defdelegate apply_external_state(mailbox_id, inbound_delivery_id, state),
    to: ExternalState,
    as: :apply

  @doc """
  Persists provider mailbox receive time onto the projected message and delivery.
  """
  @spec set_received_at(Ecto.UUID.t(), DateTime.t()) :: :ok
  defdelegate set_received_at(inbound_delivery_id, received_at), to: ReceivedAt, as: :set

  @spec clear_received_at(Ecto.UUID.t()) :: :ok
  defdelegate clear_received_at(inbound_delivery_id), to: ReceivedAt, as: :clear

  @spec stale_projection_delivery_ids(pos_integer(), pos_integer(), Keyword.t()) ::
          [Ecto.UUID.t()]
  def stale_projection_delivery_ids(parser_version, sanitizer_version, opts \\ []) do
    Projector.stale_delivery_ids(parser_version, sanitizer_version, opts)
  end

  @spec list_account_delivery_ids(Ecto.UUID.t(), Ecto.UUID.t() | nil, pos_integer()) :: %{
          ids: [Ecto.UUID.t()],
          done?: boolean()
        }
  def list_account_delivery_ids(mailbox_id, after_id, limit)
      when (is_nil(after_id) or is_binary(after_id)) and is_integer(limit) and limit > 0 do
    owned_deliveries =
      MailboxEntry
      |> where([entry], entry.mailbox_id == ^mailbox_id)
      |> select([entry], %{id: entry.inbound_delivery_id})
      |> distinct(true)

    query =
      owned_deliveries
      |> subquery()
      |> order_by([delivery], asc: delivery.id)
      |> limit(^(limit + 1))

    query =
      if is_binary(after_id) do
        where(query, [delivery], delivery.id > ^after_id)
      else
        query
      end

    ids = Repo.all(from(delivery in query, select: delivery.id))
    %{ids: Enum.take(ids, limit), done?: length(ids) <= limit}
  end

  @spec delete_mailbox_entries_batch(Ecto.UUID.t(), pos_integer()) :: %{
          deleted: non_neg_integer(),
          done?: boolean()
        }
  def delete_mailbox_entries_batch(mailbox_id, limit)
      when is_integer(limit) and limit > 0 do
    target_ids =
      MailboxEntry
      |> where([entry], entry.mailbox_id == ^mailbox_id)
      |> order_by([entry], asc: entry.id)
      |> limit(^limit)
      |> lock("FOR UPDATE SKIP LOCKED")
      |> select([entry], %{id: entry.id})

    {deleted, _rows} =
      MailboxEntry
      |> with_cte("target_mailbox_entries", as: ^target_ids, materialized: true)
      |> join(:inner, [entry], target in "target_mailbox_entries", on: target.id == entry.id)
      |> where([entry, _target], entry.mailbox_id == ^mailbox_id)
      |> Repo.delete_all()

    %{deleted: deleted, done?: not account_data_remaining?(mailbox_id)}
  end

  @spec delivery_owned?(Ecto.UUID.t()) :: boolean()
  def delivery_owned?(delivery_id) do
    Repo.exists?(where(MailboxEntry, [entry], entry.inbound_delivery_id == ^delivery_id))
  end

  @spec attachment_object_keys(module(), Ecto.UUID.t()) :: [String.t()]
  def attachment_object_keys(repo, delivery_id) do
    Attachment
    |> join(:inner, [attachment], message in Message, on: message.id == attachment.message_id)
    |> where([_attachment, message], message.inbound_delivery_id == ^delivery_id)
    |> where([attachment, _message], not is_nil(attachment.object_key))
    |> distinct(true)
    |> order_by([attachment, _message], asc: attachment.object_key)
    |> select([attachment, _message], attachment.object_key)
    |> repo.all()
  end

  @spec blob_referenced?(String.t() | nil) :: boolean()
  def blob_referenced?(object_key) when is_binary(object_key) do
    Repo.exists?(where(Attachment, [attachment], attachment.object_key == ^object_key))
  end

  def blob_referenced?(nil), do: false

  @spec account_data_remaining?(Ecto.UUID.t()) :: boolean()
  def account_data_remaining?(mailbox_id) do
    Repo.exists?(where(MailboxEntry, [entry], entry.mailbox_id == ^mailbox_id))
  end

  @spec list_folders(Ecto.UUID.t()) ::
          {:ok, [Manifold.Mail.View.Folder.t()]} | {:error, Error.t()}
  defdelegate list_folders(mailbox_id), to: Mailbox

  @spec list_conversations(Ecto.UUID.t(), Ecto.UUID.t(), Keyword.t()) ::
          {:ok, Manifold.Mail.View.ConversationPage.t()} | {:error, Error.t()}
  defdelegate list_conversations(mailbox_id, folder_id, opts \\ []), to: Mailbox

  @spec search(Ecto.UUID.t(), String.t(), Keyword.t()) ::
          {:ok, Manifold.Mail.View.ConversationPage.t()} | {:error, Error.t()}
  defdelegate search(mailbox_id, query, opts \\ []), to: Mailbox

  @spec get_conversation(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, Manifold.Mail.View.Conversation.t()} | {:error, Error.t()}
  defdelegate get_conversation(mailbox_id, thread_id), to: Mailbox

  @spec get_conversation(Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, Manifold.Mail.View.Conversation.t()} | {:error, Error.t()}
  defdelegate get_conversation(mailbox_id, folder_id, thread_id), to: Mailbox

  @spec get_message_body(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, String.t()} | {:error, Error.t()}
  defdelegate get_message_body(mailbox_id, message_id), to: Mailbox

  @spec get_reply_source(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, Manifold.Mail.View.ReplySource.t()} | {:error, Error.t()}
  defdelegate get_reply_source(mailbox_id, message_id), to: Mailbox

  @spec mark_read(Ecto.UUID.t(), [Ecto.UUID.t()], boolean()) ::
          {:ok, non_neg_integer()} | {:error, Error.t()}
  defdelegate mark_read(mailbox_id, entry_ids, read?), to: Mailbox

  @spec entry_ids_for_threads(Ecto.UUID.t(), Ecto.UUID.t(), [Ecto.UUID.t()]) ::
          {:ok, [Ecto.UUID.t()]} | {:error, Error.t()}
  defdelegate entry_ids_for_threads(mailbox_id, folder_id, thread_ids), to: Mailbox

  @spec mark_folder_read(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, non_neg_integer()} | {:error, Error.t()}
  defdelegate mark_folder_read(mailbox_id, folder_id), to: Mailbox

  @spec set_starred(Ecto.UUID.t(), [Ecto.UUID.t()], boolean()) ::
          {:ok, non_neg_integer()} | {:error, Error.t()}
  defdelegate set_starred(mailbox_id, entry_ids, starred?), to: Mailbox

  @spec move(Ecto.UUID.t(), [Ecto.UUID.t()], Ecto.UUID.t()) ::
          {:ok, non_neg_integer()} | {:error, Error.t()}
  defdelegate move(mailbox_id, entry_ids, folder_id), to: Mailbox

  @spec archive(Ecto.UUID.t(), [Ecto.UUID.t()]) ::
          {:ok, non_neg_integer()} | {:error, Error.t()}
  defdelegate archive(mailbox_id, entry_ids), to: Mailbox

  @spec trash(Ecto.UUID.t(), [Ecto.UUID.t()]) ::
          {:ok, non_neg_integer()} | {:error, Error.t()}
  defdelegate trash(mailbox_id, entry_ids), to: Mailbox

  @spec restore(Ecto.UUID.t(), [Ecto.UUID.t()]) ::
          {:ok, non_neg_integer()} | {:error, Error.t()}
  defdelegate restore(mailbox_id, entry_ids), to: Mailbox

  @spec set_delivery_quarantine(Ecto.UUID.t(), boolean()) ::
          {:ok, non_neg_integer()} | {:error, Error.t()}
  defdelegate set_delivery_quarantine(inbound_delivery_id, quarantined?), to: Mailbox

  @spec open_attachment(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, Manifold.Mail.View.AttachmentDownload.t()} | {:error, Error.t()}
  defdelegate open_attachment(mailbox_id, attachment_id), to: Mailbox
end
