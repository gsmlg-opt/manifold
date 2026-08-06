defmodule Manifold.Connectors.EAS.WBXML do
  @moduledoc false

  # Minimal ActiveSync WBXML codec for the code pages we need.
  # Document form: {page, tag, children} where children are binaries
  # or nested documents. Empty element: {page, tag, :empty}.

  import Bitwise

  @switch_page 0x00
  @end_tag 0x01
  @str_i 0x03
  @opaque_token 0xC3

  @pages %{
    0 => %{
      "Sync" => 0x05,
      "Responses" => 0x06,
      "Add" => 0x07,
      "Change" => 0x08,
      "Delete" => 0x09,
      "Fetch" => 0x0A,
      "SyncKey" => 0x0B,
      "ClientId" => 0x0C,
      "ServerId" => 0x0D,
      "Status" => 0x0E,
      "Collection" => 0x0F,
      "Class" => 0x10,
      "CollectionId" => 0x12,
      "GetChanges" => 0x13,
      "MoreAvailable" => 0x14,
      "WindowSize" => 0x15,
      "Commands" => 0x16,
      "Options" => 0x17,
      "FilterType" => 0x18,
      "Conflict" => 0x1B,
      "Collections" => 0x1C,
      "ApplicationData" => 0x1D,
      "DeletesAsMoves" => 0x1E
    },
    2 => %{
      "DateReceived" => 0x0F,
      "DisplayTo" => 0x11,
      "Importance" => 0x12,
      "Read" => 0x15,
      "Subject" => 0x14,
      "To" => 0x16,
      "Cc" => 0x17,
      "From" => 0x18,
      "ReplyTo" => 0x19,
      "InternetCPID" => 0x39
    },
    5 => %{
      "Folders" => 0x05,
      "Folder" => 0x06,
      "DisplayName" => 0x07,
      "ServerId" => 0x08,
      "ParentId" => 0x09,
      "Type" => 0x0A,
      "Status" => 0x0C,
      "Changes" => 0x0E,
      "Add" => 0x0F,
      "Delete" => 0x10,
      "Update" => 0x11,
      "SyncKey" => 0x12,
      "FolderCreate" => 0x13,
      "FolderDelete" => 0x14,
      "FolderUpdate" => 0x15,
      "FolderSync" => 0x16,
      "Count" => 0x17
    },
    14 => %{
      "Provision" => 0x05,
      "Policies" => 0x06,
      "Policy" => 0x07,
      "PolicyType" => 0x08,
      "PolicyKey" => 0x09,
      "Data" => 0x0A,
      "Status" => 0x0B,
      "RemoteWipe" => 0x0C,
      "EASProvisionDoc" => 0x0D,
      "DevicePasswordEnabled" => 0x0E,
      "AlphanumericDevicePasswordRequired" => 0x0F,
      "PasswordRecoveryEnabled" => 0x10,
      "RequireStorageCardEncryption" => 0x11,
      "AttachmentsEnabled" => 0x12,
      "MinDevicePasswordLength" => 0x13,
      "MaxInactivityTimeDeviceLock" => 0x14,
      "MaxDevicePasswordFailedAttempts" => 0x15,
      "MaxAttachmentSize" => 0x16,
      "AllowSimpleDevicePassword" => 0x17,
      "DevicePasswordExpiration" => 0x18,
      "DevicePasswordHistory" => 0x19,
      "AllowStorageCard" => 0x1A,
      "AllowCamera" => 0x1B,
      "RequireDeviceEncryption" => 0x1C,
      "AllowUnsignedApplications" => 0x1D,
      "AllowUnsignedInstallationPackages" => 0x1E,
      "MinDevicePasswordComplexCharacters" => 0x1F,
      "AllowWiFi" => 0x20,
      "AllowTextMessaging" => 0x21,
      "AllowPOPIMAPEmail" => 0x22,
      "AllowBluetooth" => 0x23,
      "AllowIrDA" => 0x24,
      "RequireManualSyncWhenRoaming" => 0x25,
      "AllowDesktopSync" => 0x26,
      "MaxCalendarAgeFilter" => 0x27,
      "AllowHTMLEmail" => 0x28,
      "MaxEmailAgeFilter" => 0x29,
      "MaxEmailBodyTruncationSize" => 0x2A,
      "MaxEmailHTMLBodyTruncationSize" => 0x2B,
      "RequireSignedSMIMEMessages" => 0x2C,
      "RequireEncryptedSMIMEMessages" => 0x2D,
      "RequireSignedSMIMEAlgorithm" => 0x2E,
      "RequireEncryptionSMIMEAlgorithm" => 0x2F,
      "AllowSMIMEEncryptionAlgorithmNegotiation" => 0x30,
      "AllowSMIMESoftCerts" => 0x31,
      "AllowBrowser" => 0x32,
      "AllowConsumerEmail" => 0x33,
      "AllowRemoteDesktop" => 0x34,
      "AllowInternetSharing" => 0x35,
      "UnapprovedInROMApplicationList" => 0x36,
      "ApplicationName" => 0x37,
      "ApprovedApplicationList" => 0x38,
      "Hash" => 0x39
    },
    17 => %{
      "BodyPreference" => 0x05,
      "Type" => 0x06,
      "TruncationSize" => 0x07,
      "AllOrNone" => 0x08,
      "Body" => 0x0A,
      "Data" => 0x0B,
      "EstimatedDataSize" => 0x0C,
      "Truncated" => 0x0D,
      "NativeBodyType" => 0x16
    },
    # Code page 18: Settings (DeviceInformation lives here; required in Provision for 14.1).
    18 => %{
      "Settings" => 0x05,
      "Status" => 0x06,
      "Get" => 0x07,
      "Set" => 0x08,
      "DeviceInformation" => 0x16,
      "Model" => 0x17,
      "IMEI" => 0x18,
      "FriendlyName" => 0x19,
      "OS" => 0x1A,
      "OSLanguage" => 0x1B,
      "PhoneNumber" => 0x1C,
      "UserAgent" => 0x20,
      "EnableOutboundSMS" => 0x21,
      "MobileOperator" => 0x22
    },
    20 => %{
      "ItemOperations" => 0x05,
      "Fetch" => 0x06,
      "Store" => 0x07,
      "Options" => 0x08,
      "Range" => 0x09,
      "Total" => 0x0A,
      "Properties" => 0x0B,
      "Data" => 0x0C,
      "Status" => 0x0D,
      "Response" => 0x0E,
      "Version" => 0x0F,
      "Schema" => 0x10,
      "Part" => 0x11,
      "EmptyFolderContents" => 0x12,
      "DeleteSubFolders" => 0x13,
      "UserName" => 0x14,
      "Password" => 0x15
    }
  }

  @page_by_token Map.new(@pages, fn {page, tags} ->
                   {page, Map.new(tags, fn {name, token} -> {token, name} end)}
                 end)

  @type node_t ::
          {non_neg_integer(), String.t(), :empty}
          | {non_neg_integer(), String.t(), [node_t() | binary()]}

  @spec encode(node_t()) :: binary()
  def encode(root) do
    {iodata, _page} = encode_node(root, 0)
    IO.iodata_to_binary([<<0x03, 0x01, 0x6A, 0x00>>, iodata])
  end

  @spec decode(binary()) :: {:ok, node_t()} | {:error, :invalid_wbxml}
  def decode(<<0x03, rest::binary>>) do
    with {:ok, _public_id, rest} <- decode_mb_u_int32(rest),
         {:ok, _charset, rest} <- decode_mb_u_int32(rest),
         {:ok, string_table_len, rest} <- decode_mb_u_int32(rest),
         true <- byte_size(rest) >= string_table_len,
         <<_string_table::binary-size(string_table_len), body::binary>> <- rest,
         {:ok, [root | _], _rest, _page} <- decode_nodes(body, 0, []) do
      {:ok, root}
    else
      _ -> {:error, :invalid_wbxml}
    end
  end

  def decode(_), do: {:error, :invalid_wbxml}

  @spec text(node_t() | binary() | nil) :: String.t() | nil
  def text(nil), do: nil
  def text(text) when is_binary(text), do: text
  def text({_page, _tag, :empty}), do: nil

  def text({_page, _tag, children}) when is_list(children) do
    Enum.find_value(children, fn
      bin when is_binary(bin) -> bin
      _ -> nil
    end)
  end

  @spec children(node_t(), String.t()) :: [node_t()]
  def children({_page, _tag, children}, name) when is_list(children) do
    Enum.filter(children, fn
      {_p, ^name, _} -> true
      _ -> false
    end)
  end

  def children(_, _), do: []

  @spec child(node_t(), String.t()) :: node_t() | nil
  def child(node, name) do
    case children(node, name) do
      [first | _] -> first
      [] -> nil
    end
  end

  @spec find(node_t(), String.t()) :: node_t() | nil
  def find(node, name) do
    case child(node, name) do
      nil ->
        case node do
          {_p, _t, children} when is_list(children) ->
            Enum.find_value(children, fn
              nested when is_tuple(nested) -> find(nested, name)
              _ -> nil
            end)

          _ ->
            nil
        end

      found ->
        found
    end
  end

  @spec find_all(node_t(), String.t()) :: [node_t()]
  def find_all(node, name) do
    acc = if match?({_, ^name, _}, node), do: [node], else: []

    case node do
      {_p, _t, children} when is_list(children) ->
        Enum.reduce(children, acc, fn
          nested, acc when is_tuple(nested) -> acc ++ find_all(nested, name)
          _, acc -> acc
        end)

      _ ->
        acc
    end
  end

  defp encode_node({page, tag, :empty}, current_page) do
    token = Map.fetch!(Map.fetch!(@pages, page), tag)
    {[switch_bytes(page, current_page), token], page}
  end

  defp encode_node({page, tag, children}, current_page) when is_list(children) do
    token = Map.fetch!(Map.fetch!(@pages, page), tag)

    {child_iodata, current} =
      Enum.reduce(children, {[], page}, fn
        child, {acc, current} when is_binary(child) ->
          {acc ++ [@str_i, child, 0x00], current}

        child, {acc, current} when is_tuple(child) ->
          {encoded, current} = encode_node(child, current)
          {acc ++ [encoded], current}
      end)

    {[switch_bytes(page, current_page), bor(token, 0x40), child_iodata, @end_tag], current}
  end

  defp switch_bytes(page, page), do: []
  defp switch_bytes(page, _current), do: [@switch_page, page]

  defp decode_nodes(<<>>, page, acc), do: {:ok, Enum.reverse(acc), <<>>, page}

  defp decode_nodes(<<@end_tag, rest::binary>>, page, acc),
    do: {:ok, Enum.reverse(acc), rest, page}

  defp decode_nodes(<<@switch_page, page, rest::binary>>, _page, acc) do
    decode_nodes(rest, page, acc)
  end

  defp decode_nodes(<<@str_i, rest::binary>>, page, acc) do
    case :binary.split(rest, <<0>>) do
      [str, rest] -> decode_nodes(rest, page, [str | acc])
      _ -> {:error, :invalid_wbxml}
    end
  end

  defp decode_nodes(<<@opaque_token, rest::binary>>, page, acc) do
    case decode_mb_u_int32(rest) do
      {:ok, len, rest} when is_integer(len) and len >= 0 and byte_size(rest) >= len ->
        <<data::binary-size(len), rest::binary>> = rest
        decode_nodes(rest, page, [data | acc])

      _ ->
        {:error, :invalid_wbxml}
    end
  end

  defp decode_nodes(<<token, rest::binary>>, page, acc) when token >= 0x05 do
    has_attrs? = band(token, 0x80) != 0
    has_content? = band(token, 0x40) != 0
    tag_token = band(token, 0x3F)
    name = Map.get(@page_by_token[page] || %{}, tag_token) || "_u#{tag_token}"

    with {:ok, rest} <- maybe_skip_attributes(rest, has_attrs?) do
      cond do
        not has_content? ->
          decode_nodes(rest, page, [{page, name, :empty} | acc])

        true ->
          case decode_nodes(rest, page, []) do
            {:ok, children, rest, page_after} ->
              decode_nodes(rest, page_after, [{page, name, children} | acc])

            error ->
              error
          end
      end
    end
  end

  defp decode_nodes(_, _, _), do: {:error, :invalid_wbxml}

  # ActiveSync does not use attributes; skip them if a nonconformant server sends any.
  defp maybe_skip_attributes(rest, false), do: {:ok, rest}

  defp maybe_skip_attributes(rest, true) do
    case skip_attributes(rest) do
      {:ok, rest} -> {:ok, rest}
      :error -> {:error, :invalid_wbxml}
    end
  end

  defp skip_attributes(<<@end_tag, rest::binary>>), do: {:ok, rest}
  defp skip_attributes(<<>>), do: :error

  defp skip_attributes(<<@str_i, rest::binary>>) do
    case :binary.split(rest, <<0>>) do
      [_str, rest] -> skip_attributes(rest)
      _ -> :error
    end
  end

  defp skip_attributes(<<_byte, rest::binary>>), do: skip_attributes(rest)

  defp decode_mb_u_int32(bin), do: decode_mb_u_int32(bin, 0, 0)

  defp decode_mb_u_int32(<<>>, _acc, _shift), do: :error

  defp decode_mb_u_int32(<<byte, rest::binary>>, acc, shift) do
    value = bor(acc, bsl(band(byte, 0x7F), shift))

    if band(byte, 0x80) == 0 do
      {:ok, value, rest}
    else
      decode_mb_u_int32(rest, value, shift + 7)
    end
  end
end
