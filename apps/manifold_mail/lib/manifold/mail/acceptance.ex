defmodule Manifold.Mail.Acceptance do
  @moduledoc false

  alias Ecto.Multi
  alias Manifold.Mail.Schema.MailboxEntry

  @spec add_entries(Multi.t(), atom(), atom(), [map() | struct()], DateTime.t()) :: Multi.t()
  def add_entries(%Multi{} = multi, step_name, delivery_step, routes, %DateTime{} = now) do
    rows = build_rows(routes, now)

    Multi.insert_all(
      multi,
      step_name,
      MailboxEntry,
      fn changes ->
        delivery = Map.fetch!(changes, delivery_step)
        Enum.map(rows, &Map.put(&1, :inbound_delivery_id, delivery.id))
      end,
      on_conflict: :nothing,
      conflict_target: [:mailbox_id, :inbound_delivery_id]
    )
  end

  @spec add_external_entry(
          Multi.t(),
          atom(),
          atom(),
          Ecto.UUID.t(),
          String.t(),
          DateTime.t()
        ) :: Multi.t()
  def add_external_entry(
        %Multi{} = multi,
        step_name,
        delivery_step,
        mailbox_id,
        recipient_address,
        %DateTime{} = _now
      ) do
    Multi.insert(
      multi,
      step_name,
      fn changes ->
        delivery = Map.fetch!(changes, delivery_step)

        MailboxEntry.changeset(%MailboxEntry{}, %{
          mailbox_id: mailbox_id,
          inbound_delivery_id: delivery.id,
          original_recipient: recipient_address,
          quarantined: true
        })
      end,
      on_conflict: :nothing,
      conflict_target: [:mailbox_id, :inbound_delivery_id]
    )
  end

  defp build_rows(routes, now) do
    routes
    |> Enum.flat_map(fn route ->
      original_recipient = field(route, :original_recipient)
      Enum.map(field(route, :mailbox_ids) || [], &{&1, original_recipient})
    end)
    |> Enum.reduce(%{}, fn {mailbox_id, original_recipient}, acc ->
      Map.put_new(acc, mailbox_id, original_recipient)
    end)
    |> Enum.sort_by(fn {mailbox_id, _recipient} -> mailbox_id end)
    |> Enum.map(fn {mailbox_id, original_recipient} ->
      %{
        id: Ecto.UUID.generate(),
        mailbox_id: mailbox_id,
        original_recipient: original_recipient,
        quarantined: true,
        inserted_at: now,
        updated_at: now
      }
    end)
  end

  defp field(%_{} = struct, key), do: struct |> Map.from_struct() |> field(key)
  defp field(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
