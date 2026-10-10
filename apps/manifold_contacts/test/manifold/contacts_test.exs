defmodule Manifold.ContactsTest do
  use Manifold.DataCase, async: true

  alias Manifold.Contacts
  alias Manifold.Data.Schema.{Contact, DAVCollection, DAVResource, ICloudConnection}
  alias Manifold.Data.SyncState

  test "create, search, update and delete a local contact" do
    assert {:ok, contact} =
             Contacts.create_contact(%{
               full_name: "Ada",
               emails: [%{"value" => "ada@example.test"}]
             })

    assert contact.collection_id == nil
    assert Enum.any?(Contacts.list_contacts(search: "ada"), &(&1.id == contact.id))
    assert Enum.any?(Contacts.list_contacts(search: "ADA@EXAMPLE.TEST"), &(&1.id == contact.id))
    assert {:ok, updated} = Contacts.update_contact(contact.id, %{full_name: "Ada Lovelace"})
    assert updated.full_name == "Ada Lovelace"
    assert Contacts.get_contact(contact.id).full_name == "Ada Lovelace"
    assert {:ok, deleted} = Contacts.delete_contact(contact.id)
    assert deleted.id == contact.id
    assert Contacts.get_contact(contact.id) == nil
  end

  test "local contacts preserve multiple values, postal details, organization and notes" do
    attrs = %{
      full_name: "Ada Lovelace",
      given_name: "Ada",
      family_name: "Lovelace",
      organization: "Analytical Engines",
      emails: [
        %{"value" => "ada@example.test", "types" => ["home"]},
        %{"value" => "ada@work.test", "types" => ["work"]}
      ],
      phones: [
        %{"value" => "+44 123", "types" => ["home"]},
        %{"value" => "+44 456", "types" => ["work"]}
      ],
      addresses: [
        %{
          "street" => "1 Engine Lane",
          "locality" => "London",
          "postal_code" => "N1",
          "country" => "UK",
          "types" => ["home"]
        }
      ],
      notes: "Call in the afternoon"
    }

    assert {:ok, contact} = Contacts.create_contact(attrs)
    stored = Contacts.get_contact(contact.id)
    for {key, value} <- attrs, do: assert(Map.fetch!(stored, key) == value)
    assert [found] = Contacts.list_contacts(search: "engine")
    assert found.id == contact.id
  end

  test "validates names and structured contact values" do
    assert {:error, blank} = Contacts.create_contact(%{full_name: "   "})
    assert blank.errors[:full_name]

    assert {:error, email} =
             Contacts.create_contact(%{full_name: "Ada", emails: [%{"value" => "not-an-email"}]})

    assert email.errors[:emails]

    assert {:error, phone} =
             Contacts.create_contact(%{full_name: "Ada", phones: [%{"value" => ""}]})

    assert phone.errors[:phones]

    assert {:error, address} =
             Contacts.create_contact(%{full_name: "Ada", addresses: [%{"street" => 42}]})

    assert address.errors[:addresses]
  end

  test "rejects null structured values and accepts atom-keyed postal maps" do
    for field <- [:emails, :phones, :addresses] do
      assert {:error, changeset} = Contacts.create_contact(%{field => nil, :full_name => "Ada"})
      assert changeset.errors[field]
    end

    assert {:ok, contact} =
             Contacts.create_contact(%{
               full_name: "Ada",
               addresses: [%{street: "1 Engine Lane", country: "UK"}]
             })

    assert [%{"street" => "1 Engine Lane", "country" => "UK"}] =
             Contacts.get_contact(contact.id).addresses
  end

  test "imported contacts remain read-only and cannot be manufactured by local CRUD" do
    collection = collection_fixture()
    imported = imported_fixture(collection)
    assert {:error, :read_only} = Contacts.update_contact(imported.id, %{full_name: "Changed"})
    assert {:error, :read_only} = Contacts.delete_contact(imported.id)
    assert Contacts.get_contact(imported.id).full_name == "Remote Ada"

    assert {:ok, local} =
             Contacts.create_contact(%{
               full_name: "Local",
               collection_id: collection.id,
               resource_href: "/forged.vcf",
               raw: "forged"
             })

    assert local.collection_id == nil
    assert local.resource_href == nil
    assert local.raw == nil

    assert {:ok, local} =
             Contacts.update_contact(local.id, %{
               collection_id: collection.id,
               resource_href: "/forged.vcf"
             })

    assert local.collection_id == nil
  end

  test "duplicate emails and remote UIDs stay independent across sources" do
    first = collection_fixture()
    second = collection_fixture()
    remote_one = imported_fixture(first)
    remote_two = imported_fixture(second)

    assert {:ok, local} =
             Contacts.create_contact(%{
               full_name: "Local Ada",
               emails: [%{"value" => "ada@example.test"}]
             })

    contacts = Contacts.list_contacts(search: "ada@example.test")

    assert MapSet.new(Enum.map(contacts, & &1.id)) ==
             MapSet.new([remote_one.id, remote_two.id, local.id])

    assert Enum.all?(contacts, fn contact ->
             is_nil(contact.collection_id) or
               (Ecto.assoc_loaded?(contact.collection) and
                  Ecto.assoc_loaded?(contact.collection.connection) and
                  is_nil(contact.collection.connection.password_ciphertext))
           end)
  end

  test "collection resource identity rejects duplicate imports" do
    collection = collection_fixture()
    imported_fixture(collection)

    changeset =
      Contact.changeset(struct(Contact), %{
        collection_id: collection.id,
        resource_href: "/ada.vcf",
        uid: "ada",
        full_name: "Duplicate"
      })

    assert {:error, duplicate} = Repo.insert(changeset)
    assert duplicate.errors[:resource_href]
  end

  test "search treats wildcard characters literally and ordering and pagination are stable" do
    assert {:ok, zed} = Contacts.create_contact(%{full_name: "Zed"})
    assert {:ok, ada} = Contacts.create_contact(%{full_name: "ada"})
    assert {:ok, percent} = Contacts.create_contact(%{full_name: "100% Real"})
    assert [%{id: id}] = Contacts.list_contacts(search: "%")
    assert id == percent.id
    assert Enum.map(Contacts.list_contacts(), & &1.id) == [percent.id, ada.id, zed.id]
    assert [%{id: id}] = Contacts.list_contacts(limit: 1, offset: 1)
    assert id == ada.id
    assert Contacts.list_contacts(limit: 0, offset: -1) != []
  end

  test "malformed and missing IDs do not raise" do
    for id <- ["bad-uuid", "", nil, Ecto.UUID.generate()] do
      assert Contacts.get_contact(id) == nil
      assert {:error, :not_found} = Contacts.update_contact(id, %{full_name: "Ada"})
      assert {:error, :not_found} = Contacts.delete_contact(id)
    end
  end

  test "connection deletion retains imported contacts and their identity" do
    first = collection_fixture()
    second = collection_fixture()
    imported_one = imported_fixture(first)
    imported_two = imported_fixture(second)
    assert {:ok, local} = Contacts.create_contact(%{full_name: "Local"})
    Repo.delete!(Repo.get!(ICloudConnection, first.connection_id))
    assert Contacts.get_contact(imported_one.id).collection_id == nil
    assert Contacts.get_contact(imported_one.id).resource_href == "/ada.vcf"
    assert Contacts.get_contact(imported_two.id).id == imported_two.id
    assert Contacts.get_contact(local.id).id == local.id
  end

  test "default preference is true without a target and account enrollment excludes unassigned contacts" do
    account = account_fixture()
    assert {:ok, local} = Contacts.create_contact(%{full_name: "Unassigned"})
    assert local.sync_to_icloud
    assert local.resource_id == nil

    assert {:ok, waiting} =
             Contacts.create_contact(%{full_name: "Waiting", account_id: account.id})

    assert waiting.resource_id == nil
    {_, collection} = target_fixture(account)
    assert {:ok, _} = SyncState.enroll_account(account.id)
    assert Contacts.get_contact(local.id).resource_id == nil
    enrolled = Contacts.get_contact(waiting.id)
    assert enrolled.resource.collection_id == collection.id
    assert enrolled.resource.status == "pending"
    assert enrolled.resource.acknowledged_revision == 0
  end

  test "local save stages durable revisions and a wakeup without contacting iCloud" do
    account = account_fixture()
    {connection, collection} = target_fixture(account)

    assert {:ok, contact} =
             Contacts.create_contact(%{full_name: "Offline Ada", account_id: account.id})

    first = Repo.get!(DAVResource, contact.resource_id)
    assert contact.local_revision == 1
    assert first.status == "pending"
    assert first.desired_revision == 1
    assert first.acknowledged_revision == 0
    assert first.base_raw == nil
    assert String.starts_with?(first.href, collection.href)
    assert first.uid != nil

    assert Repo.exists?(
             from j in Oban.Job,
               where:
                 j.worker == "Manifold.Connectors.Jobs.SyncICloud" and
                   fragment("?->>'connection_id'", j.args) == ^connection.id
           )

    assert {:ok, updated} = Contacts.update_contact(contact.id, %{full_name: "Edited offline"})
    second = Repo.get!(DAVResource, contact.resource_id)
    assert updated.local_revision == 2
    assert second.desired_revision == 2
    assert second.href == first.href
    assert second.uid == first.uid
    assert Enum.any?(SyncState.pending_resources(), &(&1.id == first.id))
  end

  test "opt-out retains binding and paused local revisions, re-enable enrolls the same identity" do
    account = account_fixture()
    target_fixture(account)
    assert {:ok, contact} = Contacts.create_contact(%{full_name: "Ada", account_id: account.id})
    resource_id = contact.resource_id
    assert {:ok, disabled} = Contacts.update_contact(contact.id, %{sync_to_icloud: false})
    assert disabled.resource_id == resource_id
    assert Repo.get!(DAVResource, resource_id).status == "paused"
    assert {:ok, _} = Contacts.update_contact(contact.id, %{full_name: "Local only"})
    assert Repo.get!(DAVResource, resource_id).status == "paused"
    assert {:ok, _} = Contacts.update_contact(contact.id, %{sync_to_icloud: true})
    assert Repo.get!(DAVResource, resource_id).status == "pending"
    assert Contacts.get_contact(contact.id).resource_id == resource_id
  end

  test "opted-out remote deletion retains a suppression tombstone and never stages a remote delete" do
    account = account_fixture()
    {_, collection} = target_fixture(account)
    imported = imported_fixture(collection)
    imported = imported |> change(account_id: account.id) |> Repo.update!()
    assert {:ok, disabled} = Contacts.update_contact(imported.id, %{sync_to_icloud: false})
    assert disabled.resource_id
    assert {:ok, _} = Contacts.delete_contact(imported.id)
    assert Contacts.get_contact(imported.id) == nil
    assert Repo.get!(Contact, imported.id).deleted_at
    binding = Repo.get!(DAVResource, disabled.resource_id)
    assert binding.status == "paused"
    assert binding.href == imported.resource_href
  end

  test "writable imports preserve clean baseline and stable IDs while editing locally" do
    account = account_fixture()
    {_, collection} = target_fixture(account)
    imported = imported_fixture(collection) |> change(account_id: account.id) |> Repo.update!()
    assert {:ok, edited} = Contacts.update_contact(imported.id, %{full_name: "Local draft"})
    binding = Repo.get!(DAVResource, edited.resource_id)
    assert edited.id == imported.id
    assert binding.base_raw == imported.raw
    assert binding.remote_raw == imported.raw
    assert binding.status == "pending"
    assert binding.acknowledged_revision == 0
    assert {:ok, _} = Contacts.delete_contact(imported.id)
    binding = Repo.get!(DAVResource, binding.id)
    assert binding.operation == "delete"
    assert binding.status == "pending"
    assert Repo.get!(Contact, imported.id).deleted_at
  end

  test "never-dispatched create then delete cancels locally, uncertain attempts remain durable" do
    account = account_fixture()
    target_fixture(account)

    assert {:ok, contact} =
             Contacts.create_contact(%{full_name: "Cancelled", account_id: account.id})

    assert {:ok, _} = Contacts.delete_contact(contact.id)
    binding = Repo.get!(DAVResource, contact.resource_id)
    assert binding.status == "synced"
    assert binding.acknowledged_revision == binding.desired_revision

    assert {:ok, unknown} =
             Contacts.create_contact(%{full_name: "In flight", account_id: account.id})

    resource = Repo.get!(DAVResource, unknown.resource_id)

    resource
    |> DAVResource.changeset(%{
      status: "uncertain",
      sent_revision: 1,
      sent_raw: "immutable request",
      sent_operation: "upsert"
    })
    |> Repo.update!()

    assert {:ok, _} = Contacts.delete_contact(unknown.id)
    retained = Repo.get!(DAVResource, resource.id)
    assert retained.status == "uncertain"
    assert retained.sent_revision == 1
    assert retained.sent_raw == "immutable request"
    assert retained.desired_revision == 2
    assert retained.operation == "delete"
  end

  test "inactive Account saves remain local while purge fences mutations" do
    account = account_fixture()
    target_fixture(account)
    account = account |> change(active: false) |> Repo.update!()

    assert {:ok, contact} =
             Contacts.create_contact(%{full_name: "Paused", account_id: account.id})

    assert Repo.get!(DAVResource, contact.resource_id).status == "paused"
    account |> change(purge_requested_at: DateTime.utc_now()) |> Repo.update!()

    assert {:error, :account_purging} =
             Contacts.update_contact(contact.id, %{full_name: "Rejected"})

    assert Contacts.get_contact(contact.id).full_name == "Paused"
  end

  test "invalid local mutations roll back revisions and bound records require explicit copy to another Account" do
    account = account_fixture()
    target_fixture(account)
    other = account_fixture()
    target_fixture(other)

    assert {:ok, contact} =
             Contacts.create_contact(%{full_name: "Original", account_id: account.id})

    assert {:error, _} = Contacts.update_contact(contact.id, %{emails: [%{"value" => "invalid"}]})
    assert Repo.get!(DAVResource, contact.resource_id).desired_revision == 1
    assert Contacts.get_contact(contact.id).local_revision == 1

    assert {:error, :local_copy_required} =
             Contacts.update_contact(contact.id, %{account_id: other.id})

    assert {:ok, copy} = Contacts.copy_contact(contact.id, %{account_id: other.id})
    assert copy.id != contact.id
    assert copy.resource_id != contact.resource_id
    assert Contacts.get_contact(contact.id).account_id == account.id
  end

  test "reassigning an unbound contact fences the previous Account's purge" do
    previous = account_fixture()
    requested = account_fixture()

    assert {:ok, contact} =
             Contacts.create_contact(%{full_name: "Retained", account_id: previous.id})

    previous |> change(purge_requested_at: DateTime.utc_now()) |> Repo.update!()

    assert {:error, :account_purging} =
             Contacts.update_contact(contact.id, %{account_id: requested.id})

    assert Contacts.get_contact(contact.id).account_id == previous.id
    assert {:error, :account_purging} = Contacts.delete_contact(contact.id)
  end

  defp account_fixture do
    domain =
      struct(Manifold.Accounts.Schema.Domain)
      |> Manifold.Accounts.Schema.Domain.changeset(%{
        name: "d#{System.unique_integer([:positive])}.example.test"
      })
      |> Repo.insert!()

    struct(Manifold.Accounts.Schema.Account)
    |> Manifold.Accounts.Schema.Account.changeset(%{domain_id: domain.id, local_part: "ada"})
    |> Repo.insert!()
  end

  defp target_fixture(account) do
    connection =
      struct(ICloudConnection)
      |> ICloudConnection.changeset(%{
        account_id: account.id,
        apple_id: "ada@example.test",
        password_ciphertext: <<1, 2, 3>>
      })
      |> Repo.insert!()

    collection =
      struct(DAVCollection)
      |> DAVCollection.changeset(%{
        connection_id: connection.id,
        kind: "contacts",
        href: "https://contacts.icloud.com/addressbook/",
        name: "Personal",
        writable: true
      })
      |> Repo.insert!()

    connection =
      connection
      |> ICloudConnection.changeset(%{default_contacts_collection_id: collection.id})
      |> Repo.update!()

    {connection, collection}
  end

  defp collection_fixture do
    connection =
      struct(ICloudConnection)
      |> ICloudConnection.changeset(%{
        apple_id: "ada@example.test",
        password_ciphertext: <<1, 2, 3>>
      })
      |> Repo.insert!()

    struct(DAVCollection)
    |> DAVCollection.changeset(%{
      connection_id: connection.id,
      kind: "contacts",
      href: "/addressbook/",
      name: "Personal"
    })
    |> Repo.insert!()
  end

  defp imported_fixture(collection) do
    struct(Contact)
    |> Contact.changeset(%{
      collection_id: collection.id,
      resource_href: "/ada.vcf",
      uid: "ada",
      full_name: "Remote Ada",
      emails: [%{"value" => "ada@example.test"}],
      raw: "BEGIN:VCARD\r\nEND:VCARD\r\n"
    })
    |> Repo.insert!()
  end
end
