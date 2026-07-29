defmodule Manifold.Repo.Migrations.AddCloudIngressIdentity do
  use Ecto.Migration

  def change do
    create table(:cloud_ingress_identities, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:source_id, :text, null: false)
      add(:external_delivery_id, :text, null: false)

      add(
        :inbound_delivery_id,
        references(:inbound_deliveries, type: :binary_id, on_delete: :restrict),
        null: false
      )

      add(:raw_sha256, :text, null: false)
      add(:raw_size, :bigint, null: false)
      add(:routes_sha256, :text, null: false)

      timestamps(type: :utc_datetime_usec)
    end

    create(
      unique_index(
        :cloud_ingress_identities,
        [:source_id, :external_delivery_id],
        name: :cloud_ingress_identities_source_delivery_index
      )
    )

    create(
      unique_index(:cloud_ingress_identities, [:inbound_delivery_id],
        name: :cloud_ingress_identities_inbound_delivery_index
      )
    )
  end
end
