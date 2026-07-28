defmodule Manifold.SMTP.Listener do
  @moduledoc """
  Builds the supervised gen_smtp listener child spec.
  """

  @spec child_spec() :: Supervisor.child_spec()
  def child_spec do
    options = [
      domain: String.to_charlist(config(:hostname)),
      address: parse_bind(config(:bind)),
      port: config(:port),
      sessionoptions: session_options()
    ]

    :gen_smtp_server.child_spec(:manifold_smtp_listener, Manifold.SMTP.Session, options)
  end

  defp session_options do
    [
      {:allow_bare_newlines, false},
      {:callbackoptions,
       [
         max_message_bytes: config(:max_message_bytes),
         max_recipients: config(:max_recipients),
         tls_enabled?: tls_enabled?()
       ]}
    ]
    |> maybe_put_tls_options()
  end

  defp maybe_put_tls_options(options) do
    certfile = config(:tls_certfile)
    keyfile = config(:tls_keyfile)

    if certfile && keyfile do
      Keyword.put(options, :tls_options,
        certfile: String.to_charlist(certfile),
        keyfile: String.to_charlist(keyfile)
      )
    else
      options
    end
  end

  defp tls_enabled?, do: config(:tls_certfile) && config(:tls_keyfile)

  defp parse_bind(bind) when is_binary(bind) do
    bind
    |> String.to_charlist()
    |> :inet.parse_address()
    |> case do
      {:ok, address} -> address
      {:error, _reason} -> raise ArgumentError, "invalid MANIFOLD_SMTP_BIND=#{bind}"
    end
  end

  defp config(key), do: Application.fetch_env!(:manifold_smtp, key)
end
