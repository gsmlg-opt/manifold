defmodule Manifold.Connectors.DAV.Client do
  @moduledoc false
  alias Manifold.Connectors.DAV.{Transport, URL, XML}
  @dav "DAV:"
  @card "urn:ietf:params:xml:ns:carddav"
  @cal "urn:ietf:params:xml:ns:caldav"
  @max_resources 5_000
  @max_body 8 * 1024 * 1024
  @max_content 64 * 1024 * 1024

  def discover(credentials, kind, opts \\ [])
      when kind in ["contacts", "calendars", :contacts, :calendars] do
    {service, properties} =
      if kind in ["contacts", :contacts],
        do: {"contacts", {@card, "addressbook-home-set", "addressbook"}},
        else: {"caldav", {@cal, "calendar-home-set", "calendar"}}

    opts = deadline(opts)

    case discover_at("https://#{service}.icloud.com/", credentials, properties, opts) do
      {:error, :nxdomain} ->
        discover_at("https://#{service}.icloud.com.cn/", credentials, properties, opts)

      result ->
        result
    end
  end

  defp discover_at(root, credentials, {namespace, home_property, collection_type}, opts) do
    with {:ok, principal_data, root} <-
           propfind(root, credentials, [{@dav, "current-user-principal"}], "0", opts),
         {:ok, principal_href} <- href_property(principal_data, {@dav, "current-user-principal"}),
         {:ok, principal} <- URL.resolve(root, principal_href),
         {:ok, home_data, principal} <-
           propfind(principal, credentials, [{namespace, home_property}], "0", opts),
         {:ok, home_href} <- href_property(home_data, {namespace, home_property}),
         {:ok, home} <- URL.resolve(principal, home_href),
         {:ok, data, home} <-
           propfind(
             home,
             credentials,
             [
               {@dav, "resourcetype"},
               {@dav, "displayname"},
               {@dav, "sync-token"},
               {@dav, "current-user-privilege-set"},
               {@cal, "supported-calendar-component-set"}
             ],
             "1",
             opts
           ),
         true <-
           Enum.any?(
             data.responses,
             &(URL.resolve(home, &1.href) == {:ok, home} && not failed?(&1))
           ) || {:error, :incomplete_snapshot},
         {:ok, collections} <- collections(data.responses, home, {namespace, collection_type}) do
      {:ok, collections}
    end
  end

  def sync_collection(collection, credentials, opts \\ []) do
    opts = deadline(opts)

    if is_binary(collection.sync_token) && collection.sync_token != "" do
      case delta(collection, credentials, opts) do
        {:error, reason} when reason in [:invalid_sync_token, :sync_not_supported] ->
          full(collection, credentials, opts)

        result ->
          result
      end
    else
      full(collection, credentials, opts)
    end
  end

  def put_resource(href, credentials, kind, body, condition, opts \\ []) do
    with true <- (is_binary(body) and byte_size(body) <= @max_body) || {:error, :content_limit},
         {:ok, conditional} <- condition_header(condition),
         content_type when not is_nil(content_type) <- content_type(kind) do
      write_request(
        :put,
        href,
        credentials,
        body,
        [conditional, {"content-type", content_type}],
        opts
      )
    else
      nil -> {:error, :invalid_kind}
      {:error, _} = error -> error
    end
  end

  def delete_resource(href, credentials, etag, opts \\ []) do
    with true <- strong_etag?(etag) || {:error, :missing_etag} do
      write_request(:delete, href, credentials, nil, [{"if-match", etag}], opts)
    end
  end

  def get_resource(href, credentials, opts \\ []) do
    with {:ok, response, final} <-
           request(
             :get,
             href,
             credentials,
             nil,
             nil,
             deadline(Keyword.put(opts, :resource_read, true))
           ),
         true <- final == href || {:error, :resource_moved} do
      case response do
        %{status: 404} ->
          {:ok, :missing}

        %{status: 200, body: body, headers: headers} ->
          etag = header(headers, "etag")

          if strong_etag?(etag),
            do: {:ok, %{content: body, etag: etag}},
            else: {:error, :missing_etag}

        %{status: 403} ->
          {:error, :forbidden}

        _ ->
          {:error, :dav_failure}
      end
    end
  end

  def strong_etag?(etag) when is_binary(etag),
    do: Regex.match?(~r/\A"[^"\x00-\x20\x7f]*"\z/, etag)

  def strong_etag?(_), do: false

  defp content_type(kind) when kind in ["contacts", :contacts], do: "text/vcard; charset=utf-8"

  defp content_type(kind) when kind in ["calendars", :calendars],
    do: "text/calendar; charset=utf-8"

  defp content_type(_), do: nil
  defp condition_header(:create), do: {:ok, {"if-none-match", "*"}}

  defp condition_header(etag),
    do: if(strong_etag?(etag), do: {:ok, {"if-match", etag}}, else: {:error, :missing_etag})

  defp write_request(method, href, credentials, body, extra_headers, opts) do
    with {:ok, href} <- URL.validate(href) do
      headers =
        extra_headers ++
          [
            {"authorization",
             "Basic " <> Base.encode64(credentials.apple_id <> ":" <> credentials.app_password)},
            {"accept-encoding", "identity"}
          ]

      transport = Keyword.get(opts, :transport, &Transport.request/4)

      case transport.(method, href, headers, body) do
        {:ok, %{status: status, headers: response_headers, body: response_body}}
        when is_binary(response_body) ->
          cond do
            byte_size(response_body) > @max_body ->
              {:error, :outcome_unknown}

            status in [200, 201, 204] and method == :delete ->
              {:ok, :deleted}

            status in [200, 201, 204] ->
              etag = header(response_headers, "etag")
              if strong_etag?(etag), do: {:ok, %{etag: etag}}, else: {:error, :outcome_unknown}

            status == 404 and method == :delete ->
              {:ok, :deleted}

            status == 412 ->
              {:error, :conflict}

            status == 401 ->
              {:error, :unauthorized}

            status == 403 ->
              {:error, :forbidden}

            status == 429 ->
              {:error, {:rate_limited, retry_after(response_headers)}}

            status in [301, 302, 303, 307, 308] ->
              {:error, :resource_moved}

            status in [400, 404, 405, 409, 415, 422, 507] ->
              {:error, :write_rejected}

            true ->
              {:error, :outcome_unknown}
          end

        _ ->
          {:error, :outcome_unknown}
      end
    end
  rescue
    _ -> {:error, :outcome_unknown}
  end

  defp privileges(response) do
    case Map.get(response.props, {@dav, "current-user-privilege-set"}) do
      nil ->
        []

      node ->
        XML.children(node, {@dav, "privilege"})
        |> Enum.flat_map(fn privilege ->
          for name <- ["all", "write", "write-content", "bind", "unbind"],
              XML.child(privilege, {@dav, name}) != nil,
              do: name
        end)
    end
  end

  defp privilege(response, name) do
    case Map.get(response.props, {@dav, "current-user-privilege-set"}) do
      nil -> nil
      _ -> Enum.any?(privileges(response), &(&1 in [name, "write", "all"]))
    end
  end

  defp components(response) do
    case Map.get(response.props, {@cal, "supported-calendar-component-set"}) do
      nil ->
        []

      node ->
        XML.children(node, {@cal, "comp"})
        |> Enum.map(fn comp -> Map.get(comp.attrs, "name") end)
        |> Enum.reject(&is_nil/1)
    end
  end

  defp supported_collection?(response, {@cal, "calendar"}) do
    is_nil(Map.get(response.props, {@cal, "supported-calendar-component-set"})) or
      "VEVENT" in components(response)
  end

  defp supported_collection?(_response, _type), do: true

  defp full(collection, credentials, opts) do
    with {:ok, data, url} <-
           propfind(
             collection.href,
             credentials,
             [{@dav, "resourcetype"}, {@dav, "getetag"}, {@dav, "sync-token"}],
             "1",
             opts
           ),
         true <-
           Enum.any?(
             data.responses,
             &(URL.resolve(url, &1.href) == {:ok, url} && not failed?(&1))
           ) || {:error, :incomplete_snapshot},
         {:ok, resources, _deleted} <- resources(data.responses, url, :full),
         {:ok, entries} <- read_entries(resources, credentials, opts) do
      token = data.sync_token || collection_property(data.responses, url, {@dav, "sync-token"})
      {:ok, %{mode: :full, entries: entries, deleted: [], sync_token: token}}
    end
  end

  defp delta(collection, credentials, opts) do
    body =
      "<?xml version=\"1.0\" encoding=\"utf-8\"?><d:sync-collection xmlns:d=\"DAV:\"><d:sync-token>#{escape(collection.sync_token)}</d:sync-token><d:sync-level>1</d:sync-level><d:prop><d:getetag/></d:prop></d:sync-collection>"

    with {:ok, response, url} <- request(:report, collection.href, credentials, body, "1", opts),
         {:ok, data} <- multistatus(response),
         true <-
           (is_binary(data.sync_token) && data.sync_token != "") || {:error, :incomplete_snapshot},
         {:ok, resources, deleted} <- resources(data.responses, url, :delta),
         {:ok, entries} <- read_entries(resources, credentials, opts) do
      {:ok, %{mode: :delta, entries: entries, deleted: deleted, sync_token: data.sync_token}}
    else
      {:error, {:http_status, status, body}} when status in [403, 409] ->
        if String.contains?(body, "valid-sync-token"),
          do: {:error, :invalid_sync_token},
          else: {:error, :dav_failure}

      other ->
        other
    end
  end

  defp propfind(url, credentials, props, depth, opts) do
    properties = Enum.map_join(props, fn {ns, name} -> "<p:#{name} xmlns:p=\"#{ns}\"/>" end)

    body =
      "<?xml version=\"1.0\" encoding=\"utf-8\"?><d:propfind xmlns:d=\"DAV:\"><d:prop>#{properties}</d:prop></d:propfind>"

    with {:ok, response, url} <- request(:propfind, url, credentials, body, depth, opts),
         {:ok, data} <- multistatus(response) do
      {:ok, data, url}
    else
      error -> sanitize(error)
    end
  end

  defp href_property(data, property) do
    hrefs =
      Enum.flat_map(data.responses, fn response ->
        case Map.get(response.props, property) do
          nil ->
            []

          node ->
            if failed?(response),
              do: [],
              else: Enum.map(XML.children(node, {@dav, "href"}), &String.trim(XML.text(&1)))
        end
      end)

    case Enum.uniq(hrefs) do
      [href] when href != "" -> {:ok, href}
      _ -> {:error, :discovery_failed}
    end
  end

  defp collections(responses, base, type) do
    if length(responses) > 65 do
      {:error, :collection_limit}
    else
      Enum.reduce_while(responses, {:ok, []}, fn response, {:ok, acc} ->
        cond do
          failed?(response) ->
            {:halt, {:error, :incomplete_snapshot}}

          not has_type?(response, type) or not supported_collection?(response, type) ->
            {:cont, {:ok, acc}}

          true ->
            case URL.resolve(base, response.href) do
              {:ok, href} ->
                {:cont,
                 {:ok,
                  [
                    %{
                      href: href,
                      name:
                        property_text(response, {@dav, "displayname"}) || "Unnamed collection",
                      sync_token: property_text(response, {@dav, "sync-token"}),
                      can_create: privilege(response, "bind"),
                      can_update: privilege(response, "write-content"),
                      can_delete: privilege(response, "unbind"),
                      privileges: privileges(response),
                      supported_components: components(response),
                      writable: privilege(response, "write-content") == true
                    }
                    | acc
                  ]}}

              error ->
                {:halt, error}
            end
        end
      end)
      |> case do
        {:ok, values} ->
          if length(Enum.uniq_by(values, & &1.href)) == length(values),
            do: {:ok, Enum.reverse(values)},
            else: {:error, :incomplete_snapshot}

        error ->
          error
      end
    end
  end

  defp resources(responses, base, mode) do
    if length(responses) > @max_resources + 1 do
      {:error, :resource_limit}
    else
      Enum.reduce_while(responses, {:ok, [], [], MapSet.new()}, fn response,
                                                                   {:ok, entries, deleted, seen} ->
        with {:ok, href} <- URL.resolve(base, response.href),
             false <- MapSet.member?(seen, href) do
          seen = MapSet.put(seen, href)

          cond do
            href == base && failed?(response) ->
              {:halt, {:error, :incomplete_snapshot}}

            failed?(response) &&
                not (mode == :delta && response.status == 404 && response.propstats == []) ->
              {:halt, {:error, :incomplete_snapshot}}

            href == base || has_type?(response, {@dav, "collection"}) ->
              {:cont, {:ok, entries, deleted, seen}}

            mode == :delta && response.status == 404 && response.propstats == [] ->
              {:cont, {:ok, entries, [href | deleted], seen}}

            failed?(response) ->
              {:halt, {:error, :incomplete_snapshot}}

            true ->
              case property_text(response, {@dav, "getetag"}) do
                etag when is_binary(etag) and etag != "" ->
                  {:cont, {:ok, [%{href: href, etag: etag} | entries], deleted, seen}}

                _ ->
                  {:halt, {:error, :incomplete_snapshot}}
              end
          end
        else
          true -> {:halt, {:error, :incomplete_snapshot}}
          error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, entries, deleted, _} -> {:ok, Enum.reverse(entries), Enum.reverse(deleted)}
        error -> error
      end
    end
  end

  defp read_entries(resources, credentials, opts) do
    existing = Keyword.get(opts, :existing_etags, %{})

    Enum.reduce_while(resources, {:ok, [], 0}, fn resource, {:ok, entries, bytes} ->
      if Map.get(existing, resource.href) == resource.etag do
        {:cont, {:ok, [Map.put(resource, :content, nil) | entries], bytes}}
      else
        case request(:get, resource.href, credentials, nil, nil, opts) do
          {:ok, %{status: 200, body: content, headers: headers}, final_url} ->
            etag = header(headers, "etag")

            cond do
              final_url != resource.href ->
                {:halt, {:error, :resource_moved}}

              bytes + byte_size(content) > @max_content ->
                {:halt, {:error, :content_limit}}

              is_binary(etag) && etag != resource.etag ->
                {:halt, {:error, :resource_changed}}

              true ->
                {:cont,
                 {:ok, [Map.put(resource, :content, content) | entries],
                  bytes + byte_size(content)}}
            end

          {:ok, _, _} ->
            {:halt, {:error, :incomplete_snapshot}}

          error ->
            {:halt, sanitize(error)}
        end
      end
    end)
    |> case do
      {:ok, entries, _} -> {:ok, Enum.reverse(entries)}
      error -> error
    end
  end

  defp request(method, url, credentials, body, depth, opts, redirects \\ 0) do
    with {:ok, url} <- URL.validate(url),
         true <-
           System.monotonic_time(:millisecond) <= Keyword.fetch!(opts, :deadline) ||
             {:error, :timeout} do
      headers = [
        {"authorization",
         "Basic " <> Base.encode64(credentials.apple_id <> ":" <> credentials.app_password)},
        {"accept", "application/xml, text/vcard, text/calendar"},
        {"accept-encoding", "identity"}
      ]

      headers =
        if body, do: [{"content-type", "application/xml; charset=utf-8"} | headers], else: headers

      headers = if depth, do: [{"depth", depth} | headers], else: headers
      transport = Keyword.get(opts, :transport, &Transport.request/4)

      case transport.(method, url, headers, body) do
        {:ok, %{status: status, body: response_body, headers: response_headers} = response}
        when is_binary(response_body) ->
          cond do
            byte_size(response_body) > @max_body ->
              {:error, :response_limit}

            status in [301, 302, 303, 307, 308] && redirects >= 3 ->
              {:error, :redirect_limit}

            status in [301, 302, 303, 307, 308] ->
              with {:ok, destination} <- URL.resolve(url, header(response_headers, "location")) do
                request(method, destination, credentials, body, depth, opts, redirects + 1)
              end

            status == 403 && Keyword.get(opts, :resource_read, false) ->
              {:error, :forbidden}

            status in [401, 403] && method != :report ->
              {:error, :unauthorized}

            status == 401 ->
              {:error, :unauthorized}

            status == 429 ->
              {:error, {:rate_limited, retry_after(response_headers)}}

            true ->
              {:ok, response, url}
          end

        {:error, reason} when reason in [:response_limit, :timeout, :nxdomain] ->
          {:error, reason}

        _ ->
          {:error, :transport_failure}
      end
    end
  rescue
    _ -> {:error, :transport_failure}
  end

  defp multistatus(%{status: 207, body: body}), do: XML.parse(body)

  defp multistatus(%{status: status, body: body}) when status in [403, 409],
    do: {:error, {:http_status, status, body}}

  defp multistatus(%{status: status}) when status in [405, 501], do: {:error, :sync_not_supported}
  defp multistatus(_), do: {:error, :dav_failure}
  defp sanitize({:error, {:http_status, _, _}}), do: {:error, :dav_failure}
  defp sanitize(error), do: error

  defp failed?(response),
    do:
      response.status not in [nil, 200, 207] ||
        Enum.any?(response.propstats, &(&1.status not in [200, 404]))

  defp has_type?(response, type) do
    case Map.get(response.props, {@dav, "resourcetype"}) do
      nil -> false
      node -> XML.child(node, type) != nil
    end
  end

  defp property_text(response, property) do
    case Map.get(response.props, property) do
      nil -> nil
      node -> String.trim(XML.text(node))
    end
  end

  defp collection_property(responses, base, property) do
    Enum.find_value(responses, fn response ->
      case URL.resolve(base, response.href) do
        {:ok, ^base} -> property_text(response, property)
        _ -> nil
      end
    end)
  end

  defp header(headers, name) when is_map(headers) do
    case Map.get(headers, name) do
      [value | _] -> value
      value when is_binary(value) -> value
      _ -> nil
    end
  end

  defp header(headers, name) when is_list(headers),
    do:
      Enum.find_value(headers, fn {key, value} -> if String.downcase(key) == name, do: value end)

  defp retry_after(headers) do
    value = header(headers, "retry-after") || "60"

    seconds =
      case Integer.parse(value) do
        {seconds, ""} ->
          seconds

        _ ->
          case :httpd_util.convert_request_date(String.to_charlist(value)) do
            {{_, _, _}, {_, _, _}} = date ->
              case NaiveDateTime.from_erl(date) do
                {:ok, datetime} ->
                  DateTime.diff(DateTime.from_naive!(datetime, "Etc/UTC"), DateTime.utc_now())

                _ ->
                  60
              end

            _ ->
              60
          end
      end

    min(max(seconds, 1), 3600)
  rescue
    _ -> 60
  end

  defp deadline(opts),
    do: Keyword.put_new(opts, :deadline, System.monotonic_time(:millisecond) + 120_000)

  defp escape(value),
    do:
      value
      |> String.replace("&", "&amp;")
      |> String.replace("<", "&lt;")
      |> String.replace(">", "&gt;")
      |> String.replace("\"", "&quot;")
end
