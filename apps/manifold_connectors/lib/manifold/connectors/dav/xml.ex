defmodule Manifold.Connectors.DAV.XML do
  @moduledoc false
  @max_bytes 8 * 1024 * 1024

  def parse(raw) when is_binary(raw) and byte_size(raw) <= @max_bytes do
    if String.valid?(raw) and not Regex.match?(~r/<!\s*(?:DOCTYPE|ENTITY)/i, raw) do
      case Saxy.parse_string(raw, __MODULE__.Handler, %{stack: [], root: nil, count: 0}) do
        {:ok, %{root: %{name: {"DAV:", "multistatus"}} = root}} ->
          responses = Enum.map(children(root, {"DAV:", "response"}), &response/1)

          if Enum.all?(responses, &(is_binary(&1.href) and &1.href != "")) do
            {:ok, %{responses: responses, sync_token: value(root, {"DAV:", "sync-token"})}}
          else
            {:error, :invalid_multistatus}
          end

        _ ->
          {:error, :invalid_xml}
      end
    else
      {:error, :invalid_xml}
    end
  rescue
    _ -> {:error, :invalid_xml}
  end

  def parse(_), do: {:error, :response_limit}

  def text(nil), do: nil
  def text(node), do: node.text
  def child(node, name), do: Enum.find(node.children, &(&1.name == name))
  def children(node, name), do: Enum.filter(node.children, &(&1.name == name))

  def value(node, name) do
    case child(node, name) do
      nil -> nil
      n -> String.trim(n.text)
    end
  end

  defp response(node) do
    propstats =
      Enum.map(children(node, {"DAV:", "propstat"}), fn ps ->
        prop = child(ps, {"DAV:", "prop"})

        %{
          status: status(value(ps, {"DAV:", "status"})),
          props: Map.new((prop && prop.children) || [], &{&1.name, &1})
        }
      end)

    props =
      Enum.filter(propstats, &(&1.status == 200)) |> Enum.reduce(%{}, &Map.merge(&2, &1.props))

    %{
      href: value(node, {"DAV:", "href"}),
      status: status(value(node, {"DAV:", "status"})),
      props: props,
      propstats: propstats
    }
  end

  defp status(nil), do: nil

  defp status(value) do
    case Regex.run(~r/\AHTTP\/\d(?:\.\d)?\s+(\d{3})(?:\s|$)/, value) do
      [_, code] -> String.to_integer(code)
      _ -> nil
    end
  end

  defmodule Handler do
    @moduledoc false
    @behaviour Saxy.Handler
    def handle_event(:start_element, {name, attrs}, state) do
      if length(state.stack) >= 64 or state.count >= 100_000 do
        {:stop, state}
      else
        inherited =
          case state.stack do
            [top | _] -> top.ns
            [] -> %{}
          end

        ns =
          Enum.reduce(attrs, inherited, fn
            {"xmlns", value}, acc -> Map.put(acc, "", value)
            {"xmlns:" <> prefix, value}, acc -> Map.put(acc, prefix, value)
            _, acc -> acc
          end)

        {prefix, local} =
          case String.split(name, ":", parts: 2) do
            [local] -> {"", local}
            [p, l] -> {p, l}
          end

        node = %{
          name: {Map.get(ns, prefix, ""), local},
          text: "",
          children: [],
          ns: ns,
          attrs: Map.new(attrs)
        }

        {:ok, %{state | stack: [node | state.stack], count: state.count + 1}}
      end
    end

    def handle_event(:characters, text, %{stack: [top | rest]} = state),
      do: {:ok, %{state | stack: [%{top | text: top.text <> text} | rest]}}

    def handle_event(:end_element, _, %{stack: [top | rest]} = state) do
      node = %{top | children: Enum.reverse(top.children)}

      case rest do
        [] ->
          {:ok, %{state | stack: [], root: node}}

        [parent | tail] ->
          {:ok, %{state | stack: [%{parent | children: [node | parent.children]} | tail]}}
      end
    end

    def handle_event(_, _, state), do: {:ok, state}
  end
end
