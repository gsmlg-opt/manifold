defmodule ManifoldWeb.MailComponents do
  @moduledoc false

  use ManifoldWeb, :html

  attr(:label, :string, required: true)
  attr(:icon, :string, required: true)
  attr(:event, :string, required: true)
  attr(:entry_id, :string, required: true)
  attr(:active, :boolean, default: false)

  def mail_action(assigns) do
    ~H"""
    <.dm_tooltip content={@label} position="bottom">
      <button
        type="button"
        class={["mail-icon-button", @active && "is-active"]}
        aria-label={@label}
        phx-click={@event}
        phx-value-entry-id={@entry_id}
      >
        <.dm_mdi name={@icon} class="mail-icon" />
      </button>
    </.dm_tooltip>
    """
  end
end
