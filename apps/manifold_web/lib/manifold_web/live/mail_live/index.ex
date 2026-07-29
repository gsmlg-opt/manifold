defmodule ManifoldWeb.MailLive.Index do
  use ManifoldWeb, :live_view

  import ManifoldWeb.MailComponents

  alias Manifold.Accounts
  alias Manifold.Mail
  alias ManifoldWeb.MailNotifier

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Mail",
       mailboxes: Accounts.list_mailboxes(),
       mailbox: nil,
       folders: [],
       folder: nil,
       page: %{items: [], next_cursor: nil},
       conversation: nil,
       query: "",
       after_cursor: nil,
       subscribed_mailbox_id: nil
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    mailbox = select_mailbox(socket.assigns.mailboxes, params["mailbox_id"])
    socket = subscribe_mailbox(socket, mailbox && mailbox.id)

    case mailbox && load_mailbox(mailbox, params) do
      nil ->
        {:noreply,
         assign(socket,
           page_title: "Mail",
           mailbox: nil,
           folders: [],
           folder: nil,
           page: %{items: [], next_cursor: nil},
           conversation: nil,
           query: "",
           after_cursor: nil
         )}

      {:ok, loaded} ->
        {:noreply,
         assign(socket,
           page_title: loaded.page_title,
           mailbox: mailbox,
           folders: loaded.folders,
           folder: loaded.folder,
           page: loaded.page,
           conversation: loaded.conversation,
           query: loaded.query,
           after_cursor: loaded.after_cursor
         )}

      {:error, _reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "The requested mailbox view is unavailable.")
         |> push_navigate(to: ~p"/")}
    end
  end

  @impl true
  def handle_event("search", %{"query" => query}, socket) do
    {:noreply,
     push_patch(socket,
       to:
         ~p"/mail/#{socket.assigns.mailbox.id}/folders/#{socket.assigns.folder.id}?#{[q: String.trim(query)]}"
     )}
  end

  def handle_event("change-mailbox", %{"mailbox_id" => mailbox_id}, socket) do
    mailbox = Enum.find(socket.assigns.mailboxes, &(&1.id == mailbox_id))

    case mailbox && Mail.list_folders(mailbox.id) do
      {:ok, folders} ->
        inbox = Enum.find(folders, &(&1.kind == "inbox"))
        {:noreply, push_navigate(socket, to: ~p"/mail/#{mailbox.id}/folders/#{inbox.id}")}

      _other ->
        {:noreply, put_flash(socket, :error, "Mailbox is unavailable.")}
    end
  end

  def handle_event("mark-read", %{"entry-id" => entry_id}, socket),
    do: mutate(socket, fn -> Mail.mark_read(socket.assigns.mailbox.id, [entry_id], true) end)

  def handle_event("mark-unread", %{"entry-id" => entry_id}, socket),
    do: mutate(socket, fn -> Mail.mark_read(socket.assigns.mailbox.id, [entry_id], false) end)

  def handle_event("star", %{"entry-id" => entry_id}, socket),
    do: mutate(socket, fn -> Mail.set_starred(socket.assigns.mailbox.id, [entry_id], true) end)

  def handle_event("unstar", %{"entry-id" => entry_id}, socket),
    do: mutate(socket, fn -> Mail.set_starred(socket.assigns.mailbox.id, [entry_id], false) end)

  def handle_event("archive", %{"entry-id" => entry_id}, socket),
    do: move_and_return(socket, fn -> Mail.archive(socket.assigns.mailbox.id, [entry_id]) end)

  def handle_event("trash", %{"entry-id" => entry_id}, socket),
    do: move_and_return(socket, fn -> Mail.trash(socket.assigns.mailbox.id, [entry_id]) end)

  def handle_event("restore", %{"entry-id" => entry_id}, socket),
    do: move_and_return(socket, fn -> Mail.restore(socket.assigns.mailbox.id, [entry_id]) end)

  def handle_event("move", %{"folder_id" => ""}, socket), do: {:noreply, socket}

  def handle_event(
        "move",
        %{"entry_id" => entry_id, "folder_id" => folder_id},
        socket
      ) do
    move_and_return(socket, fn -> Mail.move(socket.assigns.mailbox.id, [entry_id], folder_id) end)
  end

  @impl true
  def handle_info(
        {:mailbox_changed, mailbox_id},
        %{assigns: %{mailbox: %{id: mailbox_id}}} = socket
      ) do
    {:noreply, reload(socket)}
  end

  def handle_info({:mailbox_changed, _mailbox_id}, socket), do: {:noreply, socket}

  defp load_mailbox(mailbox, params) do
    with {:ok, folders} <- Mail.list_folders(mailbox.id),
         %{} = folder <- select_folder(folders, params["folder_id"]),
         query = String.trim(params["q"] || ""),
         after_cursor = params["after"],
         {:ok, page} <-
           Mail.list_conversations(mailbox.id, folder.id,
             query: query,
             after: after_cursor
           ),
         {:ok, conversation} <-
           load_conversation(mailbox.id, folder.id, params["thread_id"]) do
      {:ok,
       %{
         folders: folders,
         folder: folder,
         page: page,
         conversation: conversation,
         query: query,
         after_cursor: after_cursor,
         page_title: conversation_title(conversation, folder)
       }}
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp select_mailbox([], _id), do: nil
  defp select_mailbox(mailboxes, nil), do: List.first(mailboxes)
  defp select_mailbox(mailboxes, id), do: Enum.find(mailboxes, &(&1.id == id))

  defp select_folder(folders, nil), do: Enum.find(folders, &(&1.kind == "inbox"))
  defp select_folder(folders, id), do: Enum.find(folders, &(&1.id == id))

  defp load_conversation(_mailbox_id, _folder_id, nil), do: {:ok, nil}

  defp load_conversation(mailbox_id, folder_id, thread_id),
    do: Mail.get_conversation(mailbox_id, folder_id, thread_id)

  defp conversation_title(nil, folder), do: folder.name
  defp conversation_title(conversation, _folder), do: conversation.subject

  defp subscribe_mailbox(socket, mailbox_id) do
    if connected?(socket) and socket.assigns.subscribed_mailbox_id != mailbox_id do
      if current = socket.assigns.subscribed_mailbox_id do
        Phoenix.PubSub.unsubscribe(Manifold.PubSub, MailNotifier.mailbox_topic(current))
      end

      if mailbox_id do
        Phoenix.PubSub.subscribe(Manifold.PubSub, MailNotifier.mailbox_topic(mailbox_id))
      end
    end

    assign(socket, :subscribed_mailbox_id, mailbox_id)
  end

  defp mutate(socket, action) do
    case action.() do
      {:ok, _count} -> {:noreply, reload(socket)}
      {:error, _reason} -> {:noreply, put_flash(socket, :error, "Mailbox action failed.")}
    end
  end

  defp move_and_return(socket, action) do
    case action.() do
      {:ok, _count} ->
        {:noreply,
         push_patch(socket,
           to:
             ~p"/mail/#{socket.assigns.mailbox.id}/folders/#{socket.assigns.folder.id}?#{[q: socket.assigns.query, after: socket.assigns.after_cursor]}"
         )}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Mailbox action failed.")}
    end
  end

  defp reload(socket) do
    params =
      %{
        "mailbox_id" => socket.assigns.mailbox.id,
        "folder_id" => socket.assigns.folder.id,
        "q" => socket.assigns.query,
        "after" => socket.assigns.after_cursor
      }
      |> maybe_put_thread(socket.assigns.conversation)

    case load_mailbox(socket.assigns.mailbox, params) do
      {:ok, loaded} ->
        assign(socket,
          folders: loaded.folders,
          folder: loaded.folder,
          page: loaded.page,
          conversation: loaded.conversation,
          after_cursor: loaded.after_cursor
        )

      {:error, _reason} ->
        put_flash(socket, :error, "Mailbox refresh failed.")
    end
  end

  defp maybe_put_thread(params, nil), do: params

  defp maybe_put_thread(params, conversation),
    do: Map.put(params, "thread_id", conversation.thread_id)

  defp mailbox_label(mailbox) do
    mailbox.local_part <> "@" <> mailbox.domain.normalized_domain
  end

  defp format_time(%DateTime{} = datetime) do
    Calendar.strftime(datetime, "%b %-d, %H:%M")
  end

  defp format_size(bytes) when bytes < 1024, do: "#{bytes} B"
  defp format_size(bytes) when bytes < 1024 * 1024, do: "#{div(bytes, 1024)} KB"
  defp format_size(bytes), do: "#{Float.round(bytes / (1024 * 1024), 1)} MB"

  @impl true
  def render(assigns) do
    ~H"""
    <section class={["webmail", @conversation && "reader-open"]}>
      <aside class="mail-folders" aria-label="Mailbox folders">
        <form
          :if={@mailbox}
          id="mailbox-picker"
          phx-change="change-mailbox"
          class="mailbox-picker"
        >
          <label for="mailbox_id">Mailbox</label>
          <select id="mailbox_id" name="mailbox_id">
            <option
              :for={mailbox <- @mailboxes}
              value={mailbox.id}
              selected={mailbox.id == @mailbox.id}
            >
              {mailbox_label(mailbox)}
            </option>
          </select>
        </form>

        <nav :if={@mailbox} class="folder-list">
          <.link
            :for={folder <- @folders}
            navigate={~p"/mail/#{@mailbox.id}/folders/#{folder.id}"}
            class={["folder-link", @folder && folder.id == @folder.id && "is-current"]}
          >
            <.dm_mdi
              name={
                %{"inbox" => "inbox", "archive" => "archive", "trash" => "trash-can-outline"}[
                  folder.kind
                ] || "folder-outline"
              }
              class="folder-icon"
            />
            <span>{folder.name}</span>
            <span :if={folder.unread_count > 0} class="folder-count">{folder.unread_count}</span>
          </.link>
        </nav>

        <div class="folder-admin-links">
          <.link navigate={~p"/mailboxes"}>Manage mailboxes</.link>
          <.link navigate={~p"/domains"}>Manage domains</.link>
        </div>
      </aside>

      <div :if={is_nil(@mailbox)} class="mail-empty-instance">
        <.dm_mdi name="email-plus-outline" class="empty-icon" />
        <h1>Create a mailbox to begin</h1>
        <.link navigate={~p"/mailboxes"} class="text-command">Open mailbox settings</.link>
      </div>

      <section :if={@mailbox} class="conversation-list" aria-label="Conversations">
        <header class="conversation-list-header">
          <div>
            <h1>{@folder.name}</h1>
            <span class="mailbox-address">{mailbox_label(@mailbox)}</span>
          </div>
          <form id="mail-search" phx-submit="search" class="mail-search">
            <.dm_mdi name="magnify" class="search-icon" />
            <input
              type="search"
              name="query"
              value={@query}
              placeholder="Search mail"
              aria-label="Search mail"
            />
          </form>
        </header>

        <div :if={@page.items == []} class="empty-folder">
          <.dm_mdi name="inbox-outline" class="empty-icon" />
          <p>{if @query == "", do: "No messages in this folder", else: "No matching messages"}</p>
        </div>

        <nav class="conversation-items">
          <.link
            :for={item <- @page.items}
            navigate={
              ~p"/mail/#{@mailbox.id}/folders/#{@folder.id}/threads/#{item.thread_id}?#{[q: @query, after: @after_cursor]}"
            }
            class={[
              "conversation-row",
              item.unread && "is-unread",
              @conversation && item.thread_id == @conversation.thread_id && "is-selected"
            ]}
          >
            <span class="unread-dot" aria-hidden="true"></span>
            <div class="conversation-primary">
              <div class="conversation-meta">
                <strong>{item.sender_name || item.sender_address || "Unknown sender"}</strong>
                <time datetime={DateTime.to_iso8601(item.last_message_at)}>
                  {format_time(item.last_message_at)}
                </time>
              </div>
              <div class="conversation-subject">
                <span>{item.subject}</span>
                <span :if={item.message_count > 1} class="thread-count">{item.message_count}</span>
              </div>
              <p>{item.preview}</p>
            </div>
            <.dm_mdi :if={item.starred} name="star" class="row-state-icon starred" />
            <.dm_mdi
              :if={item.attachment_count > 0}
              name="paperclip"
              class="row-state-icon attached"
            />
          </.link>
        </nav>

        <nav
          :if={@after_cursor || @page.next_cursor}
          class="conversation-pagination"
          aria-label="Conversation pages"
        >
          <.link
            :if={@after_cursor}
            patch={~p"/mail/#{@mailbox.id}/folders/#{@folder.id}?#{[q: @query]}"}
            class="pagination-link"
          >
            First page
          </.link>
          <.link
            :if={@page.next_cursor}
            patch={
              ~p"/mail/#{@mailbox.id}/folders/#{@folder.id}?#{[q: @query, after: @page.next_cursor]}"
            }
            class="pagination-link pagination-next"
          >
            Next page <.dm_mdi name="arrow-right" class="mail-icon" />
          </.link>
        </nav>
      </section>

      <article :if={@mailbox && @conversation} class="mail-reader" aria-label="Conversation">
        <header class="reader-header">
          <.link
            patch={
              ~p"/mail/#{@mailbox.id}/folders/#{@folder.id}?#{[q: @query, after: @after_cursor]}"
            }
            class="reader-back"
            aria-label="Back to message list"
          >
            <.dm_mdi name="arrow-left" class="mail-icon" />
          </.link>
          <h2>{@conversation.subject}</h2>
        </header>

        <div class="message-stack">
          <article :for={message <- @conversation.messages} class="message-view">
            <header class="message-header">
              <div class="sender-avatar">
                {String.first(message.sender_name || message.sender_address || "?")}
              </div>
              <div class="sender-detail">
                <strong>{message.sender_name || message.sender_address || "Unknown sender"}</strong>
                <span :if={message.sender_name}>{message.sender_address}</span>
                <time datetime={DateTime.to_iso8601(message.sent_at)}>
                  {Calendar.strftime(message.sent_at, "%Y-%m-%d %H:%M UTC")}
                </time>
              </div>
              <div class="message-actions">
                <.mail_action
                  label={if message.read, do: "Mark unread", else: "Mark read"}
                  icon={if message.read, do: "email-outline", else: "email-open-outline"}
                  event={if message.read, do: "mark-unread", else: "mark-read"}
                  entry_id={message.entry_id}
                />
                <.mail_action
                  label={if message.starred, do: "Remove star", else: "Star"}
                  icon={if message.starred, do: "star", else: "star-outline"}
                  event={if message.starred, do: "unstar", else: "star"}
                  entry_id={message.entry_id}
                  active={message.starred}
                />
                <.mail_action
                  :if={@folder.kind != "archive"}
                  label="Archive"
                  icon="archive-arrow-down-outline"
                  event="archive"
                  entry_id={message.entry_id}
                />
                <.mail_action
                  :if={@folder.kind != "trash"}
                  label="Move to trash"
                  icon="trash-can-outline"
                  event="trash"
                  entry_id={message.entry_id}
                />
                <.mail_action
                  :if={@folder.kind in ["archive", "trash"]}
                  label="Restore"
                  icon="restore"
                  event="restore"
                  entry_id={message.entry_id}
                />
              </div>
            </header>

            <div class="message-body">
              <iframe
                :if={message.has_html}
                src={~p"/mailboxes/#{@mailbox.id}/messages/#{message.id}/body"}
                title={"HTML body for #{message.subject}"}
                sandbox="allow-popups"
                referrerpolicy="no-referrer"
                loading="lazy"
              ></iframe>
              <pre :if={!message.has_html}>{message.text_body || "(No readable body)"}</pre>
            </div>

            <div :if={message.attachments != []} class="attachment-list">
              <a
                :for={attachment <- message.attachments}
                href={~p"/mailboxes/#{@mailbox.id}/attachments/#{attachment.id}"}
                class="attachment-link"
              >
                <.dm_mdi name="paperclip" class="mail-icon" />
                <span>
                  <strong>{attachment.filename}</strong>
                  <small>{attachment.media_type} · {format_size(attachment.size)}</small>
                </span>
                <.dm_mdi name="download" class="mail-icon" />
              </a>
            </div>

            <form id={"move-form-#{message.entry_id}"} phx-change="move" class="move-form">
              <input type="hidden" name="entry_id" value={message.entry_id} />
              <label for={"move-#{message.entry_id}"}>Move to</label>
              <select id={"move-#{message.entry_id}"} name="folder_id">
                <option value="">Choose folder</option>
                <option :for={folder <- @folders} value={folder.id}>{folder.name}</option>
              </select>
            </form>
          </article>
        </div>
      </article>

      <aside :if={@mailbox && is_nil(@conversation)} class="reader-placeholder">
        <.dm_mdi name="email-open-outline" class="empty-icon" />
        <p>Select a conversation to read it</p>
      </aside>
    </section>
    """
  end
end
