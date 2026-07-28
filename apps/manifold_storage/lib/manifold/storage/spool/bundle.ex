defmodule Manifold.Storage.Spool.Bundle do
  @moduledoc """
  A ready persistent spool bundle.
  """

  alias Manifold.Storage.Spool.Manifest

  @type t :: %__MODULE__{
          ingest_id: String.t(),
          root: Path.t(),
          path: Path.t(),
          raw_path: Path.t(),
          manifest_path: Path.t(),
          manifest: Manifest.t()
        }

  defstruct [:ingest_id, :root, :path, :raw_path, :manifest_path, :manifest]
end
