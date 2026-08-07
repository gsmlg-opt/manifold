defmodule ManifoldWeb.OperationsComponents do
  @moduledoc false

  use ManifoldWeb, :html

  attr(:current, :atom, required: true, values: [:deliveries, :jobs])
  slot(:inner_block, required: true)

  def ops_shell(assigns) do
    ~H"""
    <section class="ops-layout">
      <aside class="ops-nav" aria-label="Operations">
        <p class="ops-nav-title">Operations</p>
        <nav class="ops-nav-list">
          <.link
            navigate={~p"/deliveries"}
            class={["ops-nav-link", @current == :deliveries && "is-current"]}
          >
            <.dm_mdi name="inbox-arrow-down-outline" class="ops-nav-icon" />
            <span>Deliveries</span>
          </.link>
          <.link navigate={~p"/jobs"} class={["ops-nav-link", @current == :jobs && "is-current"]}>
            <.dm_mdi name="timeline-clock-outline" class="ops-nav-icon" />
            <span>Jobs</span>
          </.link>
        </nav>
      </aside>
      <div class="ops-main">
        {render_slot(@inner_block)}
      </div>
    </section>
    """
  end
end
