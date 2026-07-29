defmodule ManifoldWeb.Plugs.RawBodyCapture do
  @moduledoc false

  import Plug.Conn

  @default_max_bytes 1_048_576

  @spec init(keyword()) :: keyword()
  def init(opts) do
    Keyword.put_new(opts, :max_bytes, @default_max_bytes)
  end

  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(%Plug.Conn{method: "POST"} = conn, opts) do
    if conn.request_path == Keyword.fetch!(opts, :path) do
      capture(conn, Keyword.fetch!(opts, :max_bytes))
    else
      conn
    end
  end

  def call(conn, _opts), do: conn

  @spec read_body(Plug.Conn.t(), keyword()) ::
          {:ok, binary(), Plug.Conn.t()}
          | {:more, binary(), Plug.Conn.t()}
          | {:error, term()}
  def read_body(conn, opts) do
    case conn.private do
      %{manifold_raw_body_for_parser: body} ->
        conn = %{conn | private: Map.delete(conn.private, :manifold_raw_body_for_parser)}
        {:ok, body, conn}

      _other ->
        Plug.Conn.read_body(conn, opts)
    end
  end

  defp capture(conn, max_bytes) do
    read_options = [length: max_bytes + 1, read_length: max_bytes + 1]

    case Plug.Conn.read_body(conn, read_options) do
      {:ok, body, conn} when byte_size(body) <= max_bytes ->
        conn
        |> assign(:raw_body, body)
        |> put_private(:manifold_raw_body_for_parser, body)

      {:ok, _body, conn} ->
        reject_too_large(conn)

      {:more, _partial, conn} ->
        reject_too_large(conn)

      {:error, _reason} ->
        conn
        |> send_resp(400, "Bad Request")
        |> halt()
    end
  end

  defp reject_too_large(conn) do
    conn
    |> send_resp(413, "Payload Too Large")
    |> halt()
  end
end
