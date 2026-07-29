defmodule Manifold.SMTP.Listener do
  @moduledoc """
  Builds the supervised gen_smtp listener child spec.
  """

  @spec child_spec() :: Supervisor.child_spec()
  def child_spec do
    tls = tls_config()

    options = [
      domain: String.to_charlist(config(:hostname)),
      address: parse_bind(config(:bind)),
      port: config(:port),
      ranch_opts: %{
        max_connections: config(:max_connections),
        num_acceptors: config(:acceptors)
      },
      sessionoptions: session_options(tls)
    ]

    :gen_smtp_server.child_spec(:manifold_smtp_listener, Manifold.SMTP.Session, options)
  end

  defp session_options(tls) do
    [
      {:allow_bare_newlines, false},
      {:callbackoptions,
       [
         max_message_bytes: config(:max_message_bytes),
         max_recipients: config(:max_recipients),
         admission: Manifold.SMTP.Admission,
         resolver: config(:resolver),
         ingest: config(:ingest),
         tls_enabled?: match?({:enabled, _, _}, tls)
       ]}
    ]
    |> maybe_put_tls_options(tls)
  end

  defp maybe_put_tls_options(options, {:enabled, certfile, keyfile}) do
    Keyword.put(options, :tls_options,
      certfile: String.to_charlist(certfile),
      keyfile: String.to_charlist(keyfile)
    )
  end

  defp maybe_put_tls_options(options, :disabled), do: options

  defp tls_config do
    case {config(:tls_certfile), config(:tls_keyfile)} do
      {nil, nil} ->
        :disabled

      {certfile, keyfile}
      when is_binary(certfile) and certfile != "" and is_binary(keyfile) and keyfile != "" ->
        {:enabled, certfile, keyfile}

      _partial ->
        raise ArgumentError,
              "both MANIFOLD_SMTP_TLS_CERTFILE and MANIFOLD_SMTP_TLS_KEYFILE are required"
    end
  end

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
