defmodule ManifoldWeb.Layouts do
  use ManifoldWeb, :html

  import ManifoldWeb.SettingsComponents

  embed_templates("layouts/*")
end
