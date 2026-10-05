defmodule Manifold.Connectors.DeviceOAuthTest do
  use Manifold.DataCase, async: false
  alias Manifold.Accounts
  alias Manifold.Connectors.{Crypto, DeviceOAuth, ProviderSettings}
  alias Manifold.Connectors.Provider.{Identity, Token}

  alias Manifold.Connectors.Schema.{
    OAuthAuthorization,
    OAuthDeviceTransaction,
    ReceiveMethod,
    SendMethod
  }

  alias Manifold.Core.Error
  alias Manifold.Repo

  @now ~U[2026-10-06 10:00:00.000000Z]

  defmodule FakeProvider do
    def request_device_code(_config, opts) do
      send(
        Keyword.fetch!(opts, :test_pid),
        {:device_start, Keyword.fetch!(opts, :required_scopes)}
      )

      {:ok,
       %{
         device_code: "private-device",
         user_code: "ABCD-EFGH",
         verification_uri: "https://microsoft.com/devicelogin",
         expires_in: 900,
         interval: 5
       }}
    end

    def poll_device_code("private-device", _config, opts) do
      send(Keyword.fetch!(opts, :test_pid), :provider_poll)
      if callback = Keyword.get(opts, :during_poll), do: callback.()
      Keyword.fetch!(opts, :result)
    end

    def identity(_token, _config, opts),
      do: {:ok, %Identity{id: "subject-device", email_address: Keyword.fetch!(opts, :address)}}

    def initial_cursors(_token, _config, _opts),
      do: {:ok, [%Manifold.Connectors.Provider.SyncCursor{scope: "mailbox", phase: "initial"}]}
  end

  setup do
    assert {:ok, _} =
             ProviderSettings.put("microsoft", %{
               client_id: "public-client",
               auth_flow: "device_code"
             })

    suffix = System.unique_integer([:positive])
    {:ok, domain} = Accounts.create_domain(%{name: "device#{suffix}.test"})
    {:ok, account} = Accounts.create_account(domain, %{local_part: "person"})
    account = Repo.preload(account, :domain)
    {:ok, account: account, address: Accounts.account_address(account)}
  end

  test "start encrypts the private code and first poll honors interval", %{account: account} do
    assert {:ok, view} = start(account.id)
    assert view.account_id == account.id
    assert view.purpose == "receive"
    assert view.status == "pending"
    refute Map.has_key?(view, :device_code)
    refute Map.has_key?(view, :device_code_ciphertext)
    row = Repo.get!(OAuthDeviceTransaction, view.id)
    refute row.device_code_ciphertext == "private-device"

    assert {:ok, "private-device"} =
             Crypto.decrypt(
               row.device_code_ciphertext,
               "oauth-device:microsoft:" <> account.id <> ":" <> row.id
             )

    assert_receive {:device_start, scopes}
    assert "Mail.Read" in scopes
    assert "offline_access" in scopes
    assert {:pending, %{status: "pending"}} = DeviceOAuth.poll(view.id, opts(@now))
    refute_receive :provider_poll
  end

  test "pending and slow_down persist provider pacing", %{account: account} do
    {:ok, view} = start(account.id)
    assert {:pending, %{interval: 5}} = poll(view.id, 5, {:pending, :authorization_pending})
    assert_receive :provider_poll
    assert {:pending, %{interval: 5}} = poll(view.id, 9, {:pending, :authorization_pending})
    refute_receive :provider_poll
    assert {:pending, %{interval: 10}} = poll(view.id, 10, {:pending, :slow_down})
    assert_receive :provider_poll
    assert {:pending, %{interval: 10}} = poll(view.id, 19, {:pending, :authorization_pending})
    refute_receive :provider_poll
  end

  test "receive and send share authorization while upgrading scopes", %{
    account: account,
    address: address
  } do
    {:ok, view} = start(account.id)

    assert {:ok, %ReceiveMethod{}} =
             poll(view.id, 5, token(["Mail.Read", "offline_access"]), address: address)

    assert {:ok, %{status: "complete"}} = DeviceOAuth.get(view.id)
    assert Repo.get!(OAuthDeviceTransaction, view.id).device_code_ciphertext == nil
    {:ok, view} = start(account.id, :send)
    assert_receive {:device_start, _}
    assert_receive {:device_start, scopes}
    assert "Mail.Read" in scopes and "Mail.Send" in scopes

    assert {:ok, %SendMethod{}} =
             poll(view.id, 5, token(["Mail.Read", "Mail.Send", "offline_access"]),
               address: address
             )

    assert Repo.aggregate(OAuthAuthorization, :count) == 1
    assert Repo.aggregate(ReceiveMethod, :count) == 1
    assert Repo.aggregate(SendMethod, :count) == 1
    assert {:error, %Error{}} = poll(view.id, 901, token(["Mail.Send"]), address: address)
    assert Repo.get!(OAuthDeviceTransaction, view.id).status == "complete"
  end

  test "cancel and expiry prevent provider I/O", %{account: account} do
    {:ok, view} = start(account.id)
    assert {:ok, %{status: "cancelled"}} = DeviceOAuth.cancel(view.id)
    assert {:error, %Error{}} = poll(view.id, 5, {:pending, :authorization_pending})
    refute_receive :provider_poll
    assert {:error, %Error{}} = poll(view.id, 901, {:pending, :authorization_pending})
    assert Repo.get!(OAuthDeviceTransaction, view.id).status == "cancelled"
    {:ok, view} = start(account.id)

    assert {:error, %Error{reason: :device_authorization_expired}} =
             poll(view.id, 901, {:pending, :authorization_pending})

    assert Repo.get!(OAuthDeviceTransaction, view.id).device_code_ciphertext == nil
    refute_receive :provider_poll
  end

  test "configuration rotation and inactive accounts fence polling", %{account: account} do
    {:ok, view} = start(account.id)

    assert {:ok, _} =
             ProviderSettings.put("microsoft", %{
               client_id: "other-client",
               auth_flow: "device_code"
             })

    assert {:error, %Error{reason: :provider_configuration_changed}} =
             poll(view.id, 5, {:pending, :authorization_pending})

    refute_receive :provider_poll
    {:ok, view} = start(account.id)
    assert {:ok, _} = Accounts.disable_account(account.id)

    assert {:error, %Error{reason: :account_disconnected}} =
             poll(view.id, 5, {:pending, :authorization_pending})

    refute_receive :provider_poll
  end

  test "cancellation during provider I/O prevents persistence", %{
    account: account,
    address: address
  } do
    {:ok, view} = start(account.id)
    callback = fn -> assert {:ok, _} = DeviceOAuth.cancel(view.id) end

    assert {:error, %Error{reason: :device_authorization_unavailable}} =
             poll(view.id, 5, token(["Mail.Read", "offline_access"]),
               address: address,
               during_poll: callback
             )

    assert Repo.aggregate(OAuthAuthorization, :count) == 0
    assert Repo.aggregate(ReceiveMethod, :count) == 0
  end

  test "configuration rotation during provider I/O prevents persistence", %{
    account: account,
    address: address
  } do
    {:ok, view} = start(account.id)

    callback = fn ->
      assert {:ok, _} =
               ProviderSettings.put("microsoft", %{client_id: "rotated", auth_flow: "device_code"})
    end

    assert {:error, %Error{reason: :provider_configuration_changed}} =
             poll(view.id, 5, token(["Mail.Read", "offline_access"]),
               address: address,
               during_poll: callback
             )

    assert Repo.aggregate(OAuthAuthorization, :count) == 0
  end

  test "a concurrent poll cannot issue a second provider request", %{account: account} do
    {:ok, view} = start(account.id)

    callback = fn ->
      assert {:pending, %{status: "polling"}} =
               poll(view.id, 5, {:pending, :authorization_pending})

      refute_receive :provider_poll
    end

    # Consume the outer notification before the nested poll checks its own I/O.
    callback = fn ->
      assert_receive :provider_poll
      callback.()
    end

    assert {:pending, %{status: "pending"}} =
             poll(view.id, 5, {:pending, :authorization_pending}, during_poll: callback)
  end

  test "parallel callers share exactly one live poll claim", %{account: account} do
    {:ok, view} = start(account.id)
    parent = self()
    gate = make_ref()
    options = opts(DateTime.add(@now, 5, :second))

    options =
      Keyword.put(options, :provider_opts,
        test_pid: parent,
        result: {:pending, :authorization_pending},
        during_poll: fn ->
          send(parent, {:poll_claimed, self(), gate})

          receive do
            {:release_poll, ^gate} -> :ok
          after
            5_000 -> raise "device poll gate timed out"
          end
        end
      )

    task = Task.async(fn -> DeviceOAuth.poll(view.id, options) end)
    assert_receive :provider_poll
    assert_receive {:poll_claimed, polling_pid, ^gate}
    assert {:pending, %{status: "polling"}} = poll(view.id, 5, {:pending, :authorization_pending})
    refute_receive :provider_poll
    send(polling_pid, {:release_poll, gate})
    assert {:pending, %{status: "pending"}} = Task.await(task)
  end

  test "an abandoned poll lease cannot be reclaimed or completed", %{account: account} do
    {:ok, view} = start(account.id)
    row = Repo.get!(OAuthDeviceTransaction, view.id)

    Repo.update!(
      Ecto.Changeset.change(row,
        status: "polling",
        claim_id: Ecto.UUID.generate(),
        claim_expires_at: DateTime.add(@now, 90, :second)
      )
    )

    assert {:error, %Error{reason: :device_authorization_failed}} =
             poll(view.id, 91, {:pending, :authorization_pending})

    refute_receive :provider_poll
    assert Repo.get!(OAuthDeviceTransaction, view.id).status == "failed"
    assert Repo.get!(OAuthDeviceTransaction, view.id).device_code_ciphertext == nil
  end

  test "provider identity must match the account address", %{account: account} do
    {:ok, view} = start(account.id)

    assert {:error, %Error{reason: :provider_address_mismatch}} =
             poll(view.id, 5, token(["Mail.Read", "offline_access"]),
               address: "other@example.test"
             )

    assert Repo.aggregate(OAuthAuthorization, :count) == 0
  end

  test "database connection failures return safe errors and an abandoned claim stays fenced", %{
    account: account
  } do
    {:ok, view} = start(account.id)
    callback = fn -> raise DBConnection.ConnectionError, message: "private connection details" end

    assert {:error, %Error{reason: :database_unavailable, message: message}} =
             poll(view.id, 5, {:pending, :authorization_pending}, during_poll: callback)

    refute message =~ "private"

    assert {:error, %Error{reason: :device_authorization_failed}} =
             poll(view.id, 96, {:pending, :authorization_pending})

    assert Repo.get!(OAuthDeviceTransaction, view.id).status == "failed"
  end

  test "provider errors fail permanently and never expose descriptions", %{account: account} do
    {:ok, view} = start(account.id)

    result =
      {:error,
       %Manifold.Connectors.Provider.Error{
         class: :permanent,
         code: :device_authorization_failed,
         message: "private-token-description"
       }}

    assert {:error, %Error{message: message}} = poll(view.id, 5, result)
    refute message =~ "private"
    assert Repo.get!(OAuthDeviceTransaction, view.id).status == "failed"
    assert Repo.get!(OAuthDeviceTransaction, view.id).device_code_ciphertext == nil
  end

  defp start(account_id, purpose \\ :receive),
    do: DeviceOAuth.start(account_id, purpose, opts(@now))

  defp opts(now), do: [adapter: FakeProvider, now: now, provider_opts: [test_pid: self()]]

  defp poll(id, seconds, result, provider_opts \\ []) do
    options = opts(DateTime.add(@now, seconds, :second))

    options =
      Keyword.put(
        options,
        :provider_opts,
        Keyword.merge(options[:provider_opts], [result: result] ++ provider_opts)
      )

    DeviceOAuth.poll(id, options)
  end

  defp token(scopes),
    do:
      {:ok,
       %Token{
         access_token: "access-device",
         refresh_token: "refresh-device",
         scopes: scopes,
         expires_at: DateTime.add(@now, 3600, :second)
       }}
end
