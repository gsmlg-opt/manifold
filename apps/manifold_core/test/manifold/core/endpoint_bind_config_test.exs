defmodule Manifold.Core.EndpointBindConfigTest do
  use ExUnit.Case, async: false

  @runtime_path Path.expand("../../../../../config/runtime.exs", __DIR__)
  @env_vars ~w(
    RELEASE_NAME MANIFOLD_ROLE MANIFOLD_WEB_BIND MANIFOLD_API_BIND PHX_HOST PORT API_PORT
    MANIFOLD_CONNECTOR_ENCRYPTION_KEY SECRET_KEY_BASE MANIFOLD_EDGE_API_URL
    MANIFOLD_EDGE_DATABASE_URL MANIFOLD_EDGE_SHARED_SECRET MANIFOLD_EDGE_INSTALLATION_ID
  )

  setup do
    original = Map.new(@env_vars, &{&1, System.get_env(&1)})
    Enum.each(@env_vars, &System.delete_env/1)

    System.put_env(%{
      "RELEASE_NAME" => "manifold",
      "MANIFOLD_CONNECTOR_ENCRYPTION_KEY" => Base.encode64(String.duplicate("k", 32)),
      "SECRET_KEY_BASE" => String.duplicate("s", 64)
    })

    on_exit(fn ->
      Enum.each(original, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    :ok
  end

  test "production Web and API retain wildcard addresses and existing port defaults" do
    {web, api} = endpoints()

    assert web[:http] == [ip: {0, 0, 0, 0}, port: 4290]
    assert api[:http] == [ip: {0, 0, 0, 0}, port: 4292]
    assert web[:server]
    assert api[:server]
  end

  test "Web bind does not change the API bind" do
    System.put_env("MANIFOLD_WEB_BIND", "127.0.0.1")
    {web, api} = endpoints()

    assert web[:http][:ip] == {127, 0, 0, 1}
    assert api[:http][:ip] == {0, 0, 0, 0}
  end

  test "API bind does not change the Web bind" do
    System.put_env("MANIFOLD_API_BIND", "127.0.0.2")
    {web, api} = endpoints()

    assert web[:http][:ip] == {0, 0, 0, 0}
    assert api[:http][:ip] == {127, 0, 0, 2}
  end

  test "loopback binds preserve independent ports and the public HTTPS URL" do
    System.put_env(%{
      "MANIFOLD_WEB_BIND" => "127.0.0.1",
      "MANIFOLD_API_BIND" => "127.0.0.2",
      "PORT" => "5290",
      "API_PORT" => "5292",
      "PHX_HOST" => "mail.example.com"
    })

    {web, api} = endpoints()

    assert web[:http] == [ip: {127, 0, 0, 1}, port: 5290]
    assert api[:http] == [ip: {127, 0, 0, 2}, port: 5292]
    assert web[:url] == [host: "mail.example.com", port: 443, scheme: "https"]
    assert api[:url] == web[:url]
  end

  test "both endpoints accept numeric IPv6 addresses" do
    System.put_env(%{"MANIFOLD_WEB_BIND" => "::1", "MANIFOLD_API_BIND" => "2001:db8::2"})
    {web, api} = endpoints()

    assert web[:http][:ip] == {0, 0, 0, 0, 0, 0, 0, 1}
    assert api[:http][:ip] == {0x2001, 0xDB8, 0, 0, 0, 0, 0, 2}
  end

  for env_name <- ~w(MANIFOLD_WEB_BIND MANIFOLD_API_BIND) do
    test "#{env_name} rejects hostnames, URLs, port suffixes and malformed addresses" do
      env_name = unquote(env_name)

      for invalid <- [
            "localhost",
            "http://127.0.0.1",
            "127.0.0.1:4290",
            "[::1]",
            "256.0.0.1",
            "127.1",
            ""
          ] do
        System.put_env(env_name, invalid)

        assert_raise ArgumentError,
                     "#{env_name} must be a numeric IPv4 or IPv6 address",
                     fn -> endpoints() end
      end
    end
  end

  test "bind settings do not change development or test runtime endpoints" do
    System.put_env(%{"MANIFOLD_WEB_BIND" => "invalid", "MANIFOLD_API_BIND" => "invalid"})

    for env <- [:dev, :test] do
      config = Config.Reader.read!(@runtime_path, env: env)
      refute get_in(config, [:manifold_web, ManifoldWeb.Endpoint, :http, :ip])
      refute get_in(config, [:manifold_api, ManifoldAPI.Endpoint, :http, :ip])
    end
  end

  test "Edge release ignores the main endpoint bind settings" do
    System.put_env(%{
      "RELEASE_NAME" => "manifold_edge",
      "MANIFOLD_WEB_BIND" => "invalid",
      "MANIFOLD_API_BIND" => "invalid",
      "MANIFOLD_EDGE_DATABASE_URL" => "ecto://localhost/manifold_edge",
      "MANIFOLD_EDGE_API_URL" => "https://edge.example",
      "MANIFOLD_EDGE_SHARED_SECRET" => String.duplicate("e", 32),
      "MANIFOLD_EDGE_INSTALLATION_ID" => "edge-1"
    })

    config = Config.Reader.read!(@runtime_path, env: :prod)
    refute config[:manifold_web]
    refute config[:manifold_api]
    assert config[:manifold_edge][:api_server]
  end

  defp endpoints do
    config = Config.Reader.read!(@runtime_path, env: :prod)
    {config[:manifold_web][ManifoldWeb.Endpoint], config[:manifold_api][ManifoldAPI.Endpoint]}
  end
end
