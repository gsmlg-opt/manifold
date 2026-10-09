defmodule Manifold.Connectors.ICloudTest do
  use Manifold.DataCase, async: true
  alias Manifold.Connectors.{ICloud, Crypto}
  alias Manifold.Data.Schema.ICloudConnection

  test "connect encrypts password with unique AAD and queues one secret-free job" do
    password = "aaaa-bbbb-cccc-dddd"

    assert {:ok, public} =
             ICloud.connect(%{
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
    assert {:error, :invalid_credentials} = ICloud.connect(%{apple_id: "", app_password: secret})

    assert {:error, :invalid_services} =
             ICloud.connect(%{
               apple_id: "apple@example.test",
               app_password: secret,
               contacts_enabled: false,
               calendars_enabled: false
             })

    assert {:ok, first} = ICloud.connect(%{apple_id: "apple@example.test", app_password: secret})
    assert {:ok, updated} = ICloud.update_connection(first.id, %{app_password: "replacement"})
    assert updated.generation == first.generation + 1
    assert {:ok, disabled} = ICloud.set_enabled(first.id, false)
    refute disabled.enabled
    assert {:error, :disabled} = ICloud.sync_now(first.id)
    assert {:error, :not_found} = ICloud.disconnect("not-a-uuid")
  end

  test "poll queues only enabled due connections and does not duplicate jobs" do
    {:ok, a} = ICloud.connect(%{apple_id: "one@example.test", app_password: "password"})
    {:ok, b} = ICloud.connect(%{apple_id: "two@example.test", app_password: "password"})
    {:ok, _} = ICloud.set_enabled(b.id, false)
    Repo.delete_all(Oban.Job)
    Repo.update_all(ICloudConnection, set: [next_sync_at: DateTime.add(DateTime.utc_now(), -10)])
    assert {:ok, 1} = ICloud.enqueue_due_syncs()
    assert [job] = Repo.all(Oban.Job)
    assert job.args["connection_id"] == a.id
    assert {:ok, 0} = ICloud.enqueue_due_syncs()
  end
end
