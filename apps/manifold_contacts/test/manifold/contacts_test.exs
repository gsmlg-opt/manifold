defmodule Manifold.ContactsTest do
  use Manifold.DataCase, async: true

  alias Manifold.Contacts
  alias Manifold.Data.Schema.{Contact, DAVCollection, ICloudConnection}

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

  test "connection deletion cascades imported contacts only" do
    first = collection_fixture()
    second = collection_fixture()
    imported_one = imported_fixture(first)
    imported_two = imported_fixture(second)
    assert {:ok, local} = Contacts.create_contact(%{full_name: "Local"})
    Repo.delete!(Repo.get!(ICloudConnection, first.connection_id))
    assert Contacts.get_contact(imported_one.id) == nil
    assert Contacts.get_contact(imported_two.id).id == imported_two.id
    assert Contacts.get_contact(local.id).id == local.id
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
