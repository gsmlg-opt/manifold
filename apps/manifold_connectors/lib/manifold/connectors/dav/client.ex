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
    {root, namespace, home_property, collection_type} =
      if kind in ["contacts", :contacts],
        do: {"https://contacts.icloud.com/", @card, "addressbook-home-set", "addressbook"},
        else: {"https://caldav.icloud.com/", @cal, "calendar-home-set", "calendar"}

    opts = deadline(opts)

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
             [{@dav, "resourcetype"}, {@dav, "displayname"}, {@dav, "sync-token"}],
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

          not has_type?(response, type) ->
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
                      sync_token: property_text(response, {@dav, "sync-token"})
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

            status in [401, 403] && method != :report ->
              {:error, :unauthorized}

            status == 401 ->
              {:error, :unauthorized}

            status == 429 ->
              {:error, {:rate_limited, retry_after(response_headers)}}

            true ->
              {:ok, response, url}
          end

        {:error, reason} when reason in [:response_limit, :timeout] ->
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
