defmodule Manifold.Mail do
  @moduledoc """
  Public mailbox projection and webmail context.
  """

  alias Ecto.Multi
  alias Manifold.Core.Error

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
