defmodule ManifoldAPI.Mail do
  @moduledoc """
  Thin adapter over Accounts/Mail public APIs shared by REST and GraphQL.
  """

  alias Manifold.Accounts
  alias Manifold.Core.Error
  alias Manifold.Mail
  alias ManifoldAPI.JSON

  @spec health() :: map()
  def health, do: JSON.health()

  @spec list_mailboxes() :: {:ok, [map()]}
  def list_mailboxes do
    mailboxes =
      Accounts.list_mailboxes()
      |> Enum.map(&JSON.mailbox/1)

    {:ok, mailboxes}
  end

  @spec list_folders(Ecto.UUID.t()) :: {:ok, [map()]} | {:error, Error.t()}
  def list_folders(mailbox_id) do
    with {:ok, folders} <- Mail.list_folders(mailbox_id) do
      {:ok, Enum.map(folders, &JSON.folder/1)}
    end
  end

  @spec list_conversations(Ecto.UUID.t(), Ecto.UUID.t(), Keyword.t()) ::
          {:ok, map()} | {:error, Error.t()}
  def list_conversations(mailbox_id, folder_id, opts \\ []) do
    mail_opts =
      []
      |> maybe_put(:after, Keyword.get(opts, :after))
      |> maybe_put(:limit, parse_limit(Keyword.get(opts, :limit)))
      |> maybe_put(:query, blank_to_nil(Keyword.get(opts, :q) || Keyword.get(opts, :query)))

    with {:ok, page} <- Mail.list_conversations(mailbox_id, folder_id, mail_opts) do
      {:ok, JSON.conversation_page(page)}
    end
  end

  @spec search(Ecto.UUID.t(), String.t(), Keyword.t()) :: {:ok, map()} | {:error, Error.t()}
  def search(mailbox_id, query, opts \\ []) do
    mail_opts =
      []
      |> maybe_put(:after, Keyword.get(opts, :after))
      |> maybe_put(:limit, parse_limit(Keyword.get(opts, :limit)))

    with {:ok, page} <- Mail.search(mailbox_id, query, mail_opts) do
      {:ok, JSON.conversation_page(page)}
    end
  end

  @spec get_conversation(Ecto.UUID.t(), Ecto.UUID.t()) :: {:ok, map()} | {:error, Error.t()}
  def get_conversation(mailbox_id, thread_id) do
    with {:ok, conversation} <- Mail.get_conversation(mailbox_id, thread_id) do
      {:ok, JSON.conversation(conversation, mailbox_id)}
    end
  end

  @spec get_message_body(Ecto.UUID.t(), Ecto.UUID.t()) :: {:ok, map()} | {:error, Error.t()}
  def get_message_body(mailbox_id, message_id) do
    with {:ok, source} <- Mail.get_reply_source(mailbox_id, message_id),
         {:ok, html_body} <- fetch_html_body(mailbox_id, message_id) do
      {:ok,
       JSON.message_body(%{
         text_body: source.text_body,
         html_body: html_body,
         has_html: is_binary(html_body)
       })}
    end
  end

  @spec open_attachment(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, Manifold.Mail.View.AttachmentDownload.t()} | {:error, Error.t()}
  def open_attachment(mailbox_id, attachment_id) do
    Mail.open_attachment(mailbox_id, attachment_id)
  end

  defp fetch_html_body(mailbox_id, message_id) do
    case Mail.get_message_body(mailbox_id, message_id) do
      {:ok, body} ->
        {:ok, body}

      {:error, %Error{class: class} = error} when class in [:temporary, :capacity] ->
        {:error, error}

      {:error, %Error{reason: :not_found}} ->
        {:ok, nil}

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp parse_limit(nil), do: nil

  defp parse_limit(value) when is_integer(value), do: value

  defp parse_limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {limit, ""} -> limit
      _other -> nil
    end
  end

  defp parse_limit(_other), do: nil

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
