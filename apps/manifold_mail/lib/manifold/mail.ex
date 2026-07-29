defmodule Manifold.Mail do
  @moduledoc """
  Public mailbox projection and webmail context.
  """

  alias Ecto.Multi
  alias Manifold.Core.Error
  alias Manifold.Mail.{Acceptance, InboundSource, Mailbox, ProjectionResult, Projector}

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

  @spec project_inbound(InboundSource.t(), Keyword.t()) ::
          {:ok, ProjectionResult.t()} | {:error, Error.t()}
  def project_inbound(source, opts \\ []), do: Projector.project(source, opts)

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

  @spec open_attachment(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, Manifold.Mail.View.AttachmentDownload.t()} | {:error, Error.t()}
  defdelegate open_attachment(mailbox_id, attachment_id), to: Mailbox
end
