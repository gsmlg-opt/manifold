defmodule ManifoldWeb.CoreComponents do
  @moduledoc false

  use Phoenix.Component

  attr(:flash, :map, default: %{})

  def flash_group(assigns) do
    ~H"""
    <div class="flash-group">
      <p :if={Phoenix.Flash.get(@flash, :info)} class="flash info">
        {Phoenix.Flash.get(@flash, :info)}
      </p>
      <p :if={Phoenix.Flash.get(@flash, :error)} class="flash error">
        {Phoenix.Flash.get(@flash, :error)}
      </p>
    </div>
    """
  end

  attr(:to, :string, required: true)
  slot(:inner_block, required: true)

  def nav_link(assigns) do
    ~H"""
    <.link navigate={@to} class="nav-link">{render_slot(@inner_block)}</.link>
    """
  end
end
