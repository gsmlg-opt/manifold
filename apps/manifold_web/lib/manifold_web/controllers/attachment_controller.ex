defmodule ManifoldWeb.AttachmentController do
  use ManifoldWeb, :controller

  alias Manifold.Core.Error
  alias Manifold.Mail

  def show(conn, %{"mailbox_id" => mailbox_id, "attachment_id" => attachment_id}) do
    case Mail.open_attachment(mailbox_id, attachment_id) do
      {:ok, download} ->
        disposition =
          "attachment; filename=\"attachment\"; filename*=UTF-8''" <>
            URI.encode(download.filename, &URI.char_unreserved?/1)

        conn =
          conn
          |> put_resp_header("content-type", "application/octet-stream")
          |> put_resp_header("content-disposition", disposition)
          |> put_resp_header("x-content-type-options", "nosniff")
          |> put_resp_header("cache-control", "private, no-store")
          |> send_chunked(200)

        stream_attachment(conn, download.io)

      {:error, %Error{class: :temporary}} ->
        send_resp(conn, 503, "Attachment storage temporarily unavailable")

      {:error, _reason} ->
        send_resp(conn, 404, "Attachment not found")
    end
  end

  defp stream_attachment(conn, io) do
    try do
      stream_chunks(conn, io)
    after
      _close_result = File.close(io)
    end
  end

  defp stream_chunks(conn, io) do
    case IO.binread(io, 64 * 1024) do
      :eof ->
        conn

      {:error, reason} ->
        raise File.Error,
          reason: reason,
          action: "read attachment stream",
          path: "<attachment>"

      bytes ->
        case chunk(conn, bytes) do
          {:ok, conn} -> stream_chunks(conn, io)
          {:error, :closed} -> conn
        end
    end
  end
end
