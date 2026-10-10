defmodule Manifold.Connectors.ICloudTest do
  use Manifold.DataCase, async: true
  alias Manifold.Connectors.{ICloud, Crypto}
  alias Manifold.Data.Schema.{ICloudConnection, DAVCollection, DAVResource, Contact}

  test "connect encrypts password with unique AAD and queues one secret-free job" do
    password = "aaaa-bbbb-cccc-dddd"

    assert {:ok, public} =
             connect(%{
               apple_id: "apple@example.test",
               app_password: password,
               contacts_enabled: true,
               calendars_enabled: false
             })

    refute Map.has_key?(public, :password_ciphertext)
    stored = Repo.get!(ICloudConnection, public.id)
    refute stored.password_ciphertext =~ password

    assert {:ok, ^password} =
             Crypto.decrypt(stored.password_ciphertext, "icloud:#{public.id}:app_password")

    assert {:error, _} = Crypto.decrypt(stored.password_ciphertext, "icloud:wrong:app_password")
    assert [job] = Repo.all(Oban.Job)
    assert job.args == %{"connection_id" => public.id, "generation" => 1}
    assert {:ok, repeated} = ICloud.sync_now(public.id)
    assert repeated.id == job.id
    assert length(Repo.all(Oban.Job)) == 1
  end

  test "configuration errors never carry app passwords and credentials change generation" do
    secret = "super-secret-value"
    assert {:error, :invalid_credentials} = connect(%{apple_id: "", app_password: secret})

    assert {:error, :invalid_services} =
             connect(%{
               apple_id: "apple@example.test",
               app_password: secret,
               contacts_enabled: "invalid",
               calendars_enabled: false
             })

    assert {:ok, first} = connect(%{apple_id: "apple@example.test", app_password: secret})
    assert {:ok, updated} = ICloud.update_connection(first.id, %{app_password: "replacement"})
    assert updated.generation == first.generation + 1
    assert {:ok, disabled} = ICloud.set_enabled(first.id, false)
    refute disabled.enabled
    assert {:error, :disabled} = ICloud.sync_now(first.id)
    assert {:error, :not_found} = ICloud.disconnect("not-a-uuid")
  end

  test "poll queues only enabled due connections and does not duplicate jobs" do
    {:ok, a} = connect(%{apple_id: "one@example.test", app_password: "password"})
    {:ok, b} = connect(%{apple_id: "two@example.test", app_password: "password"})
    {:ok, _} = ICloud.set_enabled(b.id, false)
    Repo.delete_all(Oban.Job)
    Repo.update_all(ICloudConnection, set: [next_sync_at: DateTime.add(DateTime.utc_now(), -10)])
    assert {:ok, 1} = ICloud.enqueue_due_syncs()
    assert [job] = Repo.all(Oban.Job)
    assert job.args["connection_id"] == a.id
    assert {:ok, 0} = ICloud.enqueue_due_syncs()
  end

  test "legacy assignment preserves resource identity and disconnect retains local data" do
    {:ok, public} = connect(%{apple_id: "legacy@example.test", app_password: "password"})
    c = Repo.get!(ICloudConnection, public.id)
    Repo.update!(Ecto.Changeset.change(c, account_id: nil))

    collection =
      Repo.insert!(
        DAVCollection.changeset(%DAVCollection{}, %{
          connection_id: c.id,
          kind: "contacts",
          href: "https://contacts.icloud.com/book/",
          name: "Book"
        })
      )

    raw = "BEGIN:VCARD\r\nVERSION:3.0\r\nUID:legacy\r\nFN:Legacy\r\nEND:VCARD\r\n"

    resource =
      Repo.insert!(
        DAVResource.changeset(%DAVResource{}, %{
          kind: "contacts",
          connection_id: c.id,
          collection_id: collection.id,
          href: collection.href <> "legacy.vcf",
          uid: "legacy",
          base_raw: raw,
          etag: "\"baseline\"",
          status: "paused"
        })
      )

    contact =
      Repo.insert!(
        Contact.changeset(%Contact{}, %{
          full_name: "Legacy",
          collection_id: collection.id,
          resource_id: resource.id,
          raw: raw,
          resource_href: resource.href,
          uid: "legacy",
          etag: resource.etag
        })
      )

    assert {:error, :account_assignment_required} = ICloud.sync_now(c.id)
    assert {:ok, assigned} = ICloud.attach(c.id, public.account_id)
    assert assigned.account_id == public.account_id
    assert Repo.get!(ICloudConnection, c.id).password_ciphertext == c.password_ciphertext
    retained = Repo.get!(DAVResource, resource.id)
    assert retained.account_id == public.account_id and retained.desired_revision == 0
    assert retained.base_raw == raw and retained.etag == resource.etag
    assert Repo.get!(Contact, contact.id).account_id == public.account_id
    assert {:ok, _} = ICloud.disconnect(c.id)
    assert Repo.get!(Contact, contact.id).raw == raw
    assert Repo.get!(DAVResource, resource.id).connection_id == nil
    assert Repo.get!(DAVResource, resource.id).status == "paused"
    assert Repo.get(DAVCollection, collection.id) == nil
  end

  test "one connection per Account and writable default destination are enforced" do
    {:ok, public} = connect(%{apple_id: "owner@example.test", app_password: "password"})

    assert {:error, :invalid_configuration} =
             ICloud.connect(%{
               account_id: public.account_id,
               apple_id: "other@example.test",
               app_password: "password"
             })

    collection =
      Repo.insert!(
        DAVCollection.changeset(%DAVCollection{}, %{
          connection_id: public.id,
          kind: "contacts",
          href: "https://contacts.icloud.com/book/",
          name: "Read only"
        })
      )

    assert {:error, :invalid_destination} =
             ICloud.update_connection(public.id, %{default_contacts_collection_id: collection.id})

    Repo.update!(Ecto.Changeset.change(collection, can_create: true))

    assert {:ok, _} =
             ICloud.update_connection(public.id, %{
               default_contacts_collection_id: collection.id,
               contacts_enabled: false,
               calendars_enabled: false
             })

    assert {:error, :disabled} = ICloud.sync_now(public.id)
  end

  defp connect(attrs) do
    {:ok, account} =
      Manifold.Accounts.create_account(%{
        address: "icloud-#{Ecto.UUID.generate()}@example.test",
        name: "iCloud test"
      })

    ICloud.connect(Map.put(attrs, :account_id, account.id))
  end
end
