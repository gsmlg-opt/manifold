defmodule Manifold.Outbound.Composition do
  @moduledoc """
  Pure preparation of reply, reply-all, and forward drafts.
  """

  alias Manifold.Core.Error

  @type address :: %{
          required(:address) => String.t(),
          optional(:display_name) => String.t() | nil
        }
  @type source :: %{
          required(:message_id) => Ecto.UUID.t(),
          required(:rfc_message_id) => String.t() | nil,
          required(:references) => [String.t()],
          required(:subject) => String.t(),
          required(:sender) => address(),
          required(:reply_to) => [address()],
          required(:to) => [address()],
          required(:cc) => [address()],
          required(:sent_at) => DateTime.t(),
          required(:text_body) => String.t() | nil
        }

  @spec prepare(:reply | :reply_all | :forward, source(), String.t()) ::
          {:ok, map()} | {:error, Error.t()}
  def prepare(kind, source, own_address) when kind in [:reply, :reply_all, :forward] do
    with {:ok, reply_target} <- reply_target(source) do
      {:ok, build(kind, source, own_address, reply_target)}
    end
  end

  def prepare(kind, _source, _own_address) do
    {:error,
     Error.new(:permanent, :invalid_composition_kind, "unsupported composition kind", %{
       kind: inspect(kind)
     })}
  end

  defp build(:reply, source, _own_address, reply_target) do
    source
    |> base("reply", reply_subject(source.subject), reply_body(source))
    |> Map.merge(%{
      to: [reply_target],
      cc: [],
      in_reply_to: source.rfc_message_id,
      references: reply_references(source)
    })
  end

  defp build(:reply_all, source, own_address, reply_target) do
    own = canonical(own_address)

    to =
      [reply_target | source.to]
      |> unique_addresses(MapSet.new([own]))

    excluded = MapSet.new([own | Enum.map(to, &canonical(&1.address))])
    cc = unique_addresses(source.cc, excluded)

    source
    |> base("reply_all", reply_subject(source.subject), reply_body(source))
    |> Map.merge(%{
      to: to,
      cc: cc,
      in_reply_to: source.rfc_message_id,
      references: reply_references(source)
    })
  end

  defp build(:forward, source, _own_address, _reply_target) do
    source
    |> base("forward", forward_subject(source.subject), forward_body(source))
    |> Map.merge(%{to: [], cc: [], in_reply_to: nil, references: []})
  end

  defp base(source, kind, subject, text_body) do
    %{
      composition_kind: kind,
      source_message_id: source.message_id,
      subject: subject,
      text_body: text_body,
      bcc: []
    }
  end

  defp reply_target(%{reply_to: [target | _rest]}), do: {:ok, target}

  defp reply_target(%{sender: %{address: address} = sender}) when is_binary(address),
    do: {:ok, sender}

  defp reply_target(_source) do
    {:error, Error.new(:permanent, :missing_reply_target, "message has no reply target")}
  end

  defp unique_addresses(addresses, excluded) do
    {result, _seen} =
      Enum.reduce(addresses, {[], excluded}, fn address, {result, seen} ->
        key = canonical(address.address)

        if key == "" or MapSet.member?(seen, key) do
          {result, seen}
        else
          {[address | result], MapSet.put(seen, key)}
        end
      end)

    Enum.reverse(result)
  end

  defp reply_references(source) do
    (source.references ++ List.wrap(source.rfc_message_id))
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
  end

  defp reply_subject(subject), do: add_prefix(subject, "Re:", ~r/^\s*re:/i)
  defp forward_subject(subject), do: add_prefix(subject, "Fwd:", ~r/^\s*fwd?:/i)

  defp add_prefix(subject, prefix, pattern) do
    subject = subject || "(No subject)"
    if Regex.match?(pattern, subject), do: subject, else: prefix <> " " <> subject
  end

  defp reply_body(source) do
    sender = author_name(source.sender)
    sent_at = Calendar.strftime(source.sent_at, "%Y-%m-%d %H:%M UTC")
    "\n\nOn #{sent_at}, #{sender} wrote:\n" <> quote_body(source.text_body)
  end

  defp forward_body(source) do
    """


    ---------- Forwarded message ----------
    From: #{display_address(source.sender)}
    Date: #{Calendar.strftime(source.sent_at, "%Y-%m-%d %H:%M UTC")}
    Subject: #{source.subject || "(No subject)"}

    #{source.text_body || ""}
    """
    |> String.trim_trailing()
  end

  defp quote_body(nil), do: ">"

  defp quote_body(body) do
    body
    |> String.split("\n")
    |> Enum.map_join("\n", fn
      "" -> ">"
      line -> "> " <> line
    end)
  end

  defp display_address(%{display_name: name, address: address})
       when is_binary(name) and name != "",
       do: "#{name} <#{address}>"

  defp display_address(%{address: address}), do: address
  defp author_name(%{display_name: name}) when is_binary(name) and name != "", do: name
  defp author_name(%{address: address}), do: address
  defp canonical(address) when is_binary(address), do: String.downcase(address, :ascii)
end
