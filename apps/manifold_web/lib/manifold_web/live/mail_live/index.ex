defmodule ManifoldWeb.MailLive.Index do
  use ManifoldWeb, :live_view

  import ManifoldWeb.MailComponents

  alias Manifold.Accounts
  alias Manifold.Mail
  alias Manifold.Outbound
  alias ManifoldWeb.MailNotifier

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Mail",
       mailboxes: Accounts.list_accounts(),
       mailbox: nil,
       folders: [],
       folder: nil,
       page: %{items: [], next_cursor: nil},
       conversation: nil,
       mail_view: :folder,
       drafts: [],
       sent_items: [],
       draft: nil,
       draft_params: nil,
       sent_detail: nil,
       query: "",
       after_cursor: nil,
       subscribed_mailbox_id: nil
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    mailbox = select_mailbox(socket.assigns.mailboxes, params["mailbox_id"])
    socket = subscribe_mailbox(socket, mailbox && mailbox.id)

    case mailbox && load_view(mailbox, socket.assigns.live_action, params) do
      nil ->
        {:noreply,
         assign(socket,
           page_title: "Mail",
           mailbox: nil,
           folders: [],
           folder: nil,
           page: %{items: [], next_cursor: nil},
           conversation: nil,
           mail_view: :folder,
           drafts: [],
           sent_items: [],
           draft: nil,
           draft_params: nil,
           sent_detail: nil,
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
           mail_view: loaded.mail_view,
           drafts: loaded.drafts,
           sent_items: loaded.sent_items,
           draft: loaded.draft,
           draft_params: draft_form_params(loaded.draft),
           sent_detail: loaded.sent_detail,
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

  def handle_event("compose", _params, %{assigns: %{mailbox: mailbox}} = socket) do
    case Outbound.create_draft(mailbox.id, %{}) do
      {:ok, draft} ->
        {:noreply, push_navigate(socket, to: ~p"/mail/#{mailbox.id}/drafts/#{draft.id}/edit")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Draft could not be created.")}
    end
  end

  def handle_event("save-draft", %{"draft" => params}, socket) do
    socket = assign(socket, :draft_params, params)

    case persist_draft(socket, params) do
      {:ok, draft} ->
        {:noreply,
         socket
         |> assign(draft: draft, draft_params: draft_form_params(draft))
         |> put_flash(:info, "Draft saved.")}

      {:error, reason} ->
        {:noreply, draft_error(socket, reason)}
    end
  end

  def handle_event("change-draft", %{"draft" => params}, socket),
    do: {:noreply, assign(socket, :draft_params, params)}

  def handle_event("save-current-draft", _params, socket) do
    case persist_draft(socket, socket.assigns.draft_params) do
      {:ok, draft} ->
        {:noreply,
         socket
         |> assign(draft: draft, draft_params: draft_form_params(draft))
         |> put_flash(:info, "Draft saved.")}

      {:error, reason} ->
        {:noreply, draft_error(socket, reason)}
    end
  end

  def handle_event("send-draft", %{"draft" => params}, socket) do
    socket = assign(socket, :draft_params, params)

    with {:ok, draft} <- persist_draft(socket, params),
         {:ok, queued} <-
           Outbound.queue_draft(socket.assigns.mailbox.id, draft.id,
             expected_revision: draft.lock_version
           ) do
      {:noreply,
       socket
       |> put_flash(:info, "Message queued for delivery.")
       |> push_navigate(to: ~p"/mail/#{socket.assigns.mailbox.id}/sent/#{queued.id}")}
    else
      {:error, reason} -> {:noreply, draft_error(socket, reason)}
    end
  end

  def handle_event("delete-draft", _params, socket) do
    case Outbound.delete_draft(socket.assigns.mailbox.id, socket.assigns.draft.id) do
      {:ok, _draft} ->
        {:noreply,
         socket
         |> put_flash(:info, "Draft deleted.")
         |> push_navigate(to: ~p"/mail/#{socket.assigns.mailbox.id}/drafts")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Draft could not be deleted.")}
    end
  end

  def handle_event(event, %{"entry-id" => message_id}, socket)
      when event in ["reply", "reply-all", "forward"] do
    kind = %{"reply" => :reply, "reply-all" => :reply_all, "forward" => :forward}[event]

    case Outbound.prepare_draft(socket.assigns.mailbox.id, message_id, kind) do
      {:ok, draft} ->
        {:noreply,
         push_navigate(
           socket,
           to: ~p"/mail/#{socket.assigns.mailbox.id}/drafts/#{draft.id}/edit"
         )}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Draft could not be prepared.")}
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
         mail_view: :folder,
         folders: folders,
         folder: folder,
         page: page,
         conversation: conversation,
         drafts: Outbound.list_drafts(mailbox.id),
         sent_items: [],
         draft: nil,
         sent_detail: nil,
         query: query,
         after_cursor: after_cursor,
         page_title: conversation_title(conversation, folder)
       }}
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp load_view(mailbox, action, params)
       when action in [:home, :folder, :conversation],
       do: load_mailbox(mailbox, params)

  defp load_view(mailbox, :drafts, _params) do
    with {:ok, folders} <- Mail.list_folders(mailbox.id) do
      {:ok,
       outbound_view(:drafts, folders,
         drafts: Outbound.list_drafts(mailbox.id),
         page_title: "Drafts"
       )}
    end
  end

  defp load_view(mailbox, :draft_edit, %{"draft_id" => draft_id}) do
    with {:ok, folders} <- Mail.list_folders(mailbox.id),
         {:ok, draft} <- Outbound.get_draft(mailbox.id, draft_id) do
      {:ok,
       outbound_view(:draft_edit, folders,
         drafts: Outbound.list_drafts(mailbox.id),
         draft: draft,
         page_title: draft.subject || "New message"
       )}
    end
  end

  defp load_view(mailbox, :sent, _params) do
    with {:ok, folders} <- Mail.list_folders(mailbox.id) do
      {:ok,
       outbound_view(:sent, folders,
         sent_items: Outbound.list_sent(mailbox.id),
         page_title: "Sent"
       )}
    end
  end

  defp load_view(mailbox, :sent_detail, %{"outbound_message_id" => message_id}) do
    with {:ok, folders} <- Mail.list_folders(mailbox.id),
         {:ok, detail} <- Outbound.get_sent(mailbox.id, message_id) do
      {:ok,
       outbound_view(:sent_detail, folders,
         sent_items: Outbound.list_sent(mailbox.id),
         sent_detail: detail,
         page_title: detail.subject
       )}
    end
  end

  defp outbound_view(mail_view, folders, overrides) do
    Map.merge(
      %{
        mail_view: mail_view,
        folders: folders,
        folder: nil,
        page: %{items: [], next_cursor: nil},
        conversation: nil,
        drafts: [],
        sent_items: [],
        draft: nil,
        sent_detail: nil,
        query: "",
        after_cursor: nil,
        page_title: "Mail"
      },
      Map.new(overrides)
    )
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
    if socket.assigns.mail_view != :folder do
      reload_outbound(socket)
    else
      reload_inbound(socket)
    end
  end

  defp reload_inbound(socket) do
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

  defp reload_outbound(socket) do
    params =
      case socket.assigns.mail_view do
        :draft_edit -> %{"draft_id" => socket.assigns.draft.id}
        :sent_detail -> %{"outbound_message_id" => socket.assigns.sent_detail.id}
        _other -> %{}
      end

    case load_view(socket.assigns.mailbox, socket.assigns.live_action, params) do
      {:ok, loaded} ->
        assign(socket,
          folders: loaded.folders,
          drafts: loaded.drafts,
          sent_items: loaded.sent_items,
          draft: loaded.draft,
          sent_detail: loaded.sent_detail
        )

      {:error, _reason} ->
        put_flash(socket, :error, "Mailbox refresh failed.")
    end
  end

  defp persist_draft(socket, params) do
    Outbound.update_draft(
      socket.assigns.mailbox.id,
      socket.assigns.draft.id,
      draft_attrs(params),
      expected_revision: socket.assigns.draft.lock_version
    )
    |> case do
      {:ok, _updated} ->
        Outbound.get_draft(socket.assigns.mailbox.id, socket.assigns.draft.id)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp draft_attrs(params) do
    %{
      subject: params["subject"],
      text_body: params["text_body"],
      recipients:
        for {kind, value} <- [
              {"to", params["to"]},
              {"cc", params["cc"]},
              {"bcc", params["bcc"]}
            ],
            address <- split_addresses(value) do
          %{kind: kind, address: address}
        end
    }
  end

  defp split_addresses(nil), do: []

  defp split_addresses(value) do
    value
    |> String.split([",", "\n"])
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp draft_error(socket, %{reason: :stale_draft}) do
    socket
    |> reload_outbound()
    |> put_flash(:error, "This draft changed in another session. Your view was refreshed.")
  end

  defp draft_error(socket, _reason),
    do: put_flash(socket, :error, "Draft could not be saved.")

  defp recipient_field(draft, kind) do
    draft.recipients
    |> Enum.filter(&(&1.kind == kind))
    |> Enum.map_join(", ", & &1.address)
  end

  defp draft_form_params(nil), do: nil

  defp draft_form_params(draft) do
    %{
      "to" => recipient_field(draft, "to"),
      "cc" => recipient_field(draft, "cc"),
      "bcc" => recipient_field(draft, "bcc"),
      "subject" => draft.subject || "",
      "text_body" => draft.text_body || ""
    }
  end

  defp maybe_put_thread(params, nil), do: params

  defp maybe_put_thread(params, conversation),
    do: Map.put(params, "thread_id", conversation.thread_id)

  defp mailbox_label(mailbox) do
    mailbox.local_part <> "@" <> mailbox.domain.normalized_domain
  end

  defp format_time(%DateTime{} = datetime) do
    ManifoldWeb.Formatting.datetime(datetime)
  end

  defp format_size(bytes) when bytes < 1024, do: "#{bytes} B"
  defp format_size(bytes) when bytes < 1024 * 1024, do: "#{div(bytes, 1024)} KB"
  defp format_size(bytes), do: "#{Float.round(bytes / (1024 * 1024), 1)} MB"

  defp outbound_state_label("accepted_by_provider"), do: "Provider accepted"
  defp outbound_state_label("submission_uncertain"), do: "Submission uncertain"
  defp outbound_state_label("queued"), do: "Queued"
  defp outbound_state_label("submitting"), do: "Sending"
  defp outbound_state_label("pending"), do: "Pending"
  defp outbound_state_label("sent"), do: "Sent"
  defp outbound_state_label("delayed"), do: "Delayed"
  defp outbound_state_label("delivered"), do: "Delivered"
  defp outbound_state_label("bounced"), do: "Bounced"
  defp outbound_state_label("complained"), do: "Complaint received"
  defp outbound_state_label("suppressed"), do: "Suppressed"
  defp outbound_state_label("failed"), do: "Failed"
  defp outbound_state_label(state), do: String.replace(state, "_", " ")

  defp outbound_event_label(event_type) do
    event_type
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp grouped_recipients(recipients) do
    for kind <- ~w(to cc bcc),
        grouped = Enum.filter(recipients, &(&1.kind == kind)),
        grouped != [] do
      {kind, grouped}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class={[
      "webmail",
      @conversation && "reader-open",
      @mail_view in [:draft_edit, :sent_detail] && "reader-open",
      @mail_view == :draft_edit && "compose-open"
    ]}>
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

        <button
          :if={@mailbox}
          id="compose-button"
          type="button"
          class="compose-button"
          phx-click="compose"
        >
          <.dm_mdi name="pencil-outline" class="mail-icon" /> Compose
        </button>

        <nav :if={@mailbox} class="folder-list">
          <.link
            navigate={~p"/mail/#{@mailbox.id}/drafts"}
            class={["folder-link", @mail_view in [:drafts, :draft_edit] && "is-current"]}
          >
            <.dm_mdi name="file-document-edit-outline" class="folder-icon" />
            <span>Drafts</span>
            <span :if={length(@drafts) > 0} class="folder-count">{length(@drafts)}</span>
          </.link>
          <.link
            navigate={~p"/mail/#{@mailbox.id}/sent"}
            class={["folder-link", @mail_view in [:sent, :sent_detail] && "is-current"]}
          >
            <.dm_mdi name="send-outline" class="folder-icon" />
            <span>Sent</span>
          </.link>
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
          <.link navigate={~p"/settings/accounts"}>Manage accounts</.link>
        </div>
      </aside>

      <div :if={is_nil(@mailbox)} class="mail-empty-instance">
        <.dm_mdi name="email-plus-outline" class="empty-icon" />
        <h1>Connect an email account</h1>
        <.link navigate={~p"/settings/accounts/new"} class="text-command">Add account</.link>
        <.link navigate={~p"/settings/accounts"}>Manage accounts</.link>
      </div>

      <section
        :if={@mailbox && @mail_view == :folder}
        class="conversation-list"
        aria-label="Conversations"
      >
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

      <section
        :if={@mailbox && @mail_view in [:drafts, :draft_edit]}
        class="conversation-list outbound-list"
        aria-label="Drafts"
      >
        <header class="conversation-list-header">
          <div>
            <h1>Drafts</h1>
            <span class="mailbox-address">{mailbox_label(@mailbox)}</span>
          </div>
        </header>
        <div :if={@drafts == []} class="empty-folder">
          <.dm_mdi name="file-document-edit-outline" class="empty-icon" />
          <p>No saved drafts</p>
        </div>
        <nav class="conversation-items">
          <.link
            :for={item <- @drafts}
            navigate={~p"/mail/#{@mailbox.id}/drafts/#{item.id}/edit"}
            class={["conversation-row", @draft && item.id == @draft.id && "is-selected"]}
          >
            <div class="conversation-primary">
              <div class="conversation-meta">
                <strong>{item.subject}</strong>
                <time datetime={DateTime.to_iso8601(item.updated_at)}>
                  {format_time(item.updated_at)}
                </time>
              </div>
              <p>{item.preview}</p>
            </div>
          </.link>
        </nav>
      </section>

      <section
        :if={@mailbox && @mail_view in [:sent, :sent_detail]}
        class="conversation-list outbound-list"
        aria-label="Sent messages"
      >
        <header class="conversation-list-header">
          <div>
            <h1>Sent</h1>
            <span class="mailbox-address">{mailbox_label(@mailbox)}</span>
          </div>
        </header>
        <div :if={@sent_items == []} class="empty-folder">
          <.dm_mdi name="send-outline" class="empty-icon" />
          <p>No sent messages</p>
        </div>
        <nav class="conversation-items">
          <.link
            :for={item <- @sent_items}
            navigate={~p"/mail/#{@mailbox.id}/sent/#{item.id}"}
            class={[
              "conversation-row",
              @sent_detail && item.id == @sent_detail.id && "is-selected"
            ]}
          >
            <div class="conversation-primary">
              <div class="conversation-meta">
                <strong>{Enum.join(item.recipients, ", ")}</strong>
                <time :if={item.queued_at} datetime={DateTime.to_iso8601(item.queued_at)}>
                  {format_time(item.queued_at)}
                </time>
              </div>
              <div class="conversation-subject">
                <span>{item.subject}</span>
              </div>
              <p>{outbound_state_label(item.state)}</p>
            </div>
          </.link>
        </nav>
      </section>

      <article
        :if={@mailbox && @mail_view == :draft_edit && @draft}
        class="mail-reader draft-editor"
        aria-label="Draft editor"
      >
        <header class="reader-header">
          <.link
            navigate={~p"/mail/#{@mailbox.id}/drafts"}
            class="reader-back"
            aria-label="Back to drafts"
          >
            <.dm_mdi name="arrow-left" class="mail-icon" />
          </.link>
          <h2>{if @draft.composition_kind == "new", do: "New message", else: "Edit draft"}</h2>
        </header>
        <form
          id="outbound-draft-form"
          class="draft-form"
          phx-change="change-draft"
          phx-submit="send-draft"
        >
          <div class="draft-address-row">
            <label>From</label>
            <span>{@draft.sender_address}</span>
          </div>
          <label>
            <span>To</span>
            <input
              type="text"
              name="draft[to]"
              value={@draft_params["to"]}
              autocomplete="off"
              placeholder="recipient@example.com"
            />
          </label>
          <label>
            <span>Cc</span>
            <input
              type="text"
              name="draft[cc]"
              value={@draft_params["cc"]}
              autocomplete="off"
            />
          </label>
          <label>
            <span>Bcc</span>
            <input
              type="text"
              name="draft[bcc]"
              value={@draft_params["bcc"]}
              autocomplete="off"
            />
          </label>
          <label class="draft-subject">
            <span>Subject</span>
            <input type="text" name="draft[subject]" value={@draft_params["subject"]} />
          </label>
          <label class="draft-body">
            <span class="sr-only">Message body</span>
            <textarea name="draft[text_body]">{@draft_params["text_body"]}</textarea>
          </label>
          <footer class="draft-actions">
            <button type="submit" class="send-button">
              <.dm_mdi name="send" class="mail-icon" /> Send
            </button>
            <button type="button" class="text-command" phx-click="save-current-draft">
              Save draft
            </button>
            <button type="button" class="danger-command" phx-click="delete-draft">
              <.dm_mdi name="trash-can-outline" class="mail-icon" />
              <span class="sr-only">Delete draft</span>
            </button>
          </footer>
        </form>
      </article>

      <article
        :if={@mailbox && @mail_view == :sent_detail && @sent_detail}
        class="mail-reader sent-reader"
        aria-label="Sent message"
      >
        <header class="reader-header">
          <.link
            navigate={~p"/mail/#{@mailbox.id}/sent"}
            class="reader-back"
            aria-label="Back to sent messages"
          >
            <.dm_mdi name="arrow-left" class="mail-icon" />
          </.link>
          <h2>{@sent_detail.subject}</h2>
          <span class={["delivery-status", "state-#{@sent_detail.state}"]}>
            {outbound_state_label(@sent_detail.state)}
          </span>
        </header>
        <div class="sent-message">
          <dl class="sent-envelope">
            <div>
              <dt>From</dt><dd>{@sent_detail.sender_address}</dd>
            </div>
            <div :for={{kind, recipients} <- grouped_recipients(@sent_detail.recipients)}>
              <dt>{String.upcase(kind)}</dt>
              <dd>{Enum.map_join(recipients, ", ", & &1.address)}</dd>
            </div>
          </dl>
          <pre class="sent-body">{@sent_detail.text_body || ""}</pre>
          <section class="delivery-timeline" aria-label="Delivery status">
            <h3>Delivery status</h3>
            <div :for={recipient <- @sent_detail.recipients} class="recipient-status">
              <span>{recipient.address}</span>
              <strong>{outbound_state_label(recipient.delivery_state)}</strong>
            </div>
            <ol>
              <li :for={event <- @sent_detail.events}>
                <time datetime={DateTime.to_iso8601(event.occurred_at)}>
                  {format_time(event.occurred_at)}
                </time>
                <span>{outbound_event_label(event.event_type)}</span>
              </li>
            </ol>
          </section>
        </div>
      </article>

      <article
        :if={@mailbox && @mail_view == :folder && @conversation}
        class="mail-reader"
        aria-label="Conversation"
      >
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
                  {ManifoldWeb.Formatting.datetime_utc(message.sent_at)}
                </time>
              </div>
              <div class="message-actions">
                <.mail_action
                  label="Reply"
                  icon="reply"
                  event="reply"
                  entry_id={message.id}
                />
                <.mail_action
                  label="Reply all"
                  icon="reply-all"
                  event="reply-all"
                  entry_id={message.id}
                />
                <.mail_action
                  label="Forward"
                  icon="forward"
                  event="forward"
                  entry_id={message.id}
                />
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

      <aside
        :if={
          @mailbox &&
            ((@mail_view == :folder && is_nil(@conversation)) ||
               @mail_view in [:drafts, :sent])
        }
        class="reader-placeholder"
      >
        <.dm_mdi name="email-open-outline" class="empty-icon" />
        <p>
          {case @mail_view do
            :drafts -> "Select a draft to edit it"
            :sent -> "Select a sent message"
            _folder -> "Select a conversation to read it"
          end}
        </p>
      </aside>
    </section>
    """
  end
end
