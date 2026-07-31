defmodule ManifoldAPI.ErrorJSON do
  def render(template, _assigns) do
    %{
      error: %{
        reason: "http_error",
        message: Phoenix.Controller.status_message_from_template(template),
        class: "permanent"
      }
    }
  end
end
