defmodule ManifoldWeb.ExternalAccountLive.Activity do
  use ManifoldWeb, :live_view

  alias Manifold.Connectors

  @impl Phoenix.LiveView
  def mount(%{"id" => id}, _session, socket) do
    case Connectors.get_account(id) do
      {:ok, account} ->
        today = Date.utc_today()

        {:ok,
         socket
         |> assign(
           page_title: "Account activity",
           account: account,
           selected_date: today,
           available_dates: available_dates(account.id, today),
           entries: load_entries(account.id, today)
         )}

      {:error, _} ->
        {:ok,
         socket
         |> put_flash(:error, "External account not found.")
         |> push_navigate(to: ~p"/settings/accounts")}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("select_date", %{"date" => date_string}, socket) do
    date =
      case Date.from_iso8601(date_string) do
        {:ok, date} -> date
        _ -> socket.assigns.selected_date
      end

    account_id = socket.assigns.account.id

    {:noreply,
     assign(socket,
       selected_date: date,
       available_dates: available_dates(account_id, date),
       entries: load_entries(account_id, date)
     )}
  end

  def handle_event("refresh", _params, socket) do
    account_id = socket.assigns.account.id
    date = socket.assigns.selected_date

    {:noreply,
     assign(socket,
       available_dates: available_dates(account_id, date),
       entries: load_entries(account_id, date)
     )}
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <section id="account-activity">
      <div class="settings-heading">
        <div>
          <h1>Activity</h1>
          <p class="settings-intro">
            Connection and sync events for {@account.email_address}.
          </p>
        </div>
        <div class="settings-heading-actions">
          <.link navigate={~p"/settings/accounts"} class="settings-action">
            Back to accounts
          </.link>
          <button
            id="activity-refresh"
            type="button"
            class="settings-action"
            phx-click="refresh"
          >
            Refresh
          </button>
        </div>
      </div>

      <form phx-change="select_date" id="activity-date-form">
        <label for="activity-date">Date</label>
        <select id="activity-date" name="date">
          <option
            :for={date <- @available_dates}
            value={Date.to_iso8601(date)}
            selected={date == @selected_date}
          >
            {Date.to_iso8601(date)}
          </option>
        </select>
      </form>

      <div :if={@entries == []} id="activity-empty" class="settings-empty">
        No activity for this day.
      </div>

      <ol :if={@entries != []} id="activity-entries" class="activity-entries">
        <li :for={entry <- @entries} class="activity-entry">
          <time>{entry["timestamp"]}</time>
          <strong>{event_label(entry["event"])}</strong>
          <span class={"activity-result result-#{entry_result(entry)}"}>
            {entry_result(entry)}
          </span>
          <span :if={entry_error_code(entry)} class="activity-error-code">{entry_error_code(entry)}</span>
          <span :if={entry_error(entry)} class="settings-error">{entry_error(entry)}</span>
          <span class="settings-secondary">{duration_label(entry)}</span>
        </li>
      </ol>
    </section>
    """
  end

  defp available_dates(account_id, selected) do
    dates =
      case Connectors.list_activity_dates(account_id) do
        {:ok, dates} -> dates
        _ -> []
      end

    [selected | dates]
    |> Enum.uniq()
    |> Enum.sort({:desc, Date})
  end

  defp load_entries(account_id, date) do
    case Connectors.read_activity(account_id, date) do
      {:ok, entries} -> entries
      _ -> []
    end
  end

  defp event_label(event) when is_list(event), do: Enum.join(event, ".")
  defp event_label(_), do: "unknown"

  defp entry_result(%{"metadata" => %{"result" => result}}) when is_binary(result), do: result
  defp entry_result(_), do: "unknown"

  defp entry_error(%{"metadata" => %{"error_message" => message}}) when is_binary(message),
    do: message

  defp entry_error(%{"metadata" => %{"error_code" => code}}) when is_binary(code), do: code
  defp entry_error(_), do: nil

  defp entry_error_code(%{"metadata" => %{"error_code" => code}}) when is_binary(code), do: code
  defp entry_error_code(_), do: nil

  defp duration_label(%{"measurements" => %{"duration_ms" => ms}}) when is_integer(ms),
    do: "#{ms} ms"

  defp duration_label(_), do: nil
end
