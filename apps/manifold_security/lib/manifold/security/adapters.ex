defmodule Manifold.Security.AuthenticationAdapter do
  @moduledoc """
  Boundary for SPF, DKIM, and DMARC evaluation.
  """

  alias Manifold.Core.Error
  alias Manifold.Security.Input

  @callback evaluate(keyword(), Input.t()) :: {:ok, map()} | {:error, Error.t()}
end

defmodule Manifold.Security.MalwareAdapter do
  @moduledoc """
  Boundary for raw-message malware scanning.
  """

  alias Manifold.Core.Error
  alias Manifold.Security.Input

  @callback scan(keyword(), Input.t()) :: {:ok, map()} | {:error, Error.t()}
end

defmodule Manifold.Security.SpamAdapter do
  @moduledoc """
  Boundary for inbound spam classification.
  """

  alias Manifold.Core.Error
  alias Manifold.Security.Input

  @callback classify(keyword(), Input.t()) :: {:ok, map()} | {:error, Error.t()}
end

defmodule Manifold.Security.Adapters.NotEvaluatedAuthentication do
  @moduledoc false
  @behaviour Manifold.Security.AuthenticationAdapter

  @impl true
  def evaluate(_config, _input) do
    {:ok,
     %{
       spf: :not_evaluated,
       dkim: :not_evaluated,
       dmarc: :not_evaluated,
       metadata: %{}
     }}
  end
end

defmodule Manifold.Security.Adapters.NotEvaluatedMalware do
  @moduledoc false
  @behaviour Manifold.Security.MalwareAdapter

  @impl true
  def scan(_config, _input),
    do: {:ok, %{verdict: :not_evaluated, signature: nil, metadata: %{}}}
end

defmodule Manifold.Security.Adapters.NotEvaluatedSpam do
  @moduledoc false
  @behaviour Manifold.Security.SpamAdapter

  @impl true
  def classify(_config, _input),
    do: {:ok, %{verdict: :not_evaluated, score: nil, metadata: %{}}}
end
