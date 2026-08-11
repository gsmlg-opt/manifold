defmodule Manifold.Outbound.RfcMessageTest do
  use ExUnit.Case, async: true

  alias Manifold.Core.Error
  alias Manifold.Outbound.Provider.Envelope
  alias Manifold.Outbound.RfcMessage

  @date ~U[2026-08-11 03:04:05Z]
  @message_id "<3f40abf2-5ae5-4f4a-91ee-981686f7949b@manifold.local>"

  @envelope %Envelope{
    from: "Sender Name <sender@example.com>",
    to: ["recipient@example.net"],
    cc: ["Copy Person <copy@example.net>"],
    bcc: ["hidden@example.net"],
    subject: "Project 进展",
    text: "Hello, 世界!\n.leading dot\r\nlast line",
    in_reply_to: "<reply@example.net>",
    references: [
      "<first-long-message-identifier@example.net>",
      "<second-long-message-identifier@example.net>",
      "<reply@example.net>"
    ],
    idempotency_key: "018f5f6e-3d31-7ef0-a5b6-2a3ed1647601"
  }

  test "renders deterministic UTF-8 text messages with CRLF and reply headers" do
    opts = [provider: :gmail, message_id: @message_id, date: @date]

    assert {:ok, raw} = RfcMessage.render(@envelope, opts)
    assert raw == RfcMessage.render!(@envelope, opts)
    assert raw == RfcMessage.render!(@envelope, opts)

    assert raw =~ "Date: Tue, 11 Aug 2026 03:04:05 +0000\r\n"
    assert raw =~ "Message-ID: #{@message_id}\r\n"
    assert raw =~ "Subject: =?UTF-8?B?UHJvamVjdCDov5vlsZU=?=\r\n"
    assert raw =~ "In-Reply-To: <reply@example.net>\r\n"

    assert raw =~
             "References: <first-long-message-identifier@example.net>\r\n" <>
               " <second-long-message-identifier@example.net> <reply@example.net>\r\n"

    assert raw =~ "MIME-Version: 1.0\r\n"
    assert raw =~ "Content-Type: text/plain; charset=UTF-8\r\n"
    assert raw =~ "Content-Transfer-Encoding: quoted-printable\r\n"
    assert raw =~ "Hello, =E4=B8=96=E7=95=8C!\r\n.leading dot\r\nlast line\r\n"

    refute Regex.match?(~r/(?<!\r)\n/, raw)
    refute Regex.match?(~r/\r(?!\n)/, raw)
  end

  test "includes Bcc for Gmail and omits it for SMTP without changing envelope recipients" do
    gmail_opts = [provider: :gmail, message_id: @message_id, date: @date]
    smtp_opts = [provider: :smtp, message_id: @message_id, date: @date]

    gmail_raw = RfcMessage.render!(@envelope, gmail_opts)
    smtp_raw = RfcMessage.render!(@envelope, smtp_opts)

    assert gmail_raw =~ "Bcc: hidden@example.net\r\n"
    refute smtp_raw =~ "Bcc:"
    assert @envelope.bcc == ["hidden@example.net"]
    assert gmail_raw == RfcMessage.render!(@envelope, gmail_opts)
    assert smtp_raw == RfcMessage.render!(@envelope, smtp_opts)
  end

  test "preserves dot-leading body lines before SMTP framing" do
    raw =
      RfcMessage.render!(@envelope,
        provider: :smtp,
        message_id: @message_id,
        date: @date
      )

    assert raw =~ "\r\n.leading dot\r\n"
    refute raw =~ "\r\n..leading dot\r\n"
  end

  test "rejects header injection without including message content in the error" do
    injected = %{
      @envelope
      | subject: "private body marker\r\nBcc: attacker@example.net",
        text: "secret body value"
    }

    assert {:error,
            %Error{
              class: :permanent,
              reason: :invalid_rfc_message,
              details: %{}
            } = error} =
             RfcMessage.render(injected,
               provider: :gmail,
               message_id: @message_id,
               date: @date
             )

    refute inspect(error) =~ "private body marker"
    refute inspect(error) =~ "secret body value"
    refute inspect(error) =~ "attacker@example.net"
  end

  test "rejects invalid addresses and reply header values safely" do
    for envelope <- [
          %{@envelope | to: ["not an address"]},
          %{@envelope | in_reply_to: "<reply@example.net>\nX-Test: injected"},
          %{@envelope | references: ["not-a-message-id"]}
        ] do
      assert {:error, %Error{reason: :invalid_rfc_message, details: %{}} = error} =
               RfcMessage.render(envelope,
                 provider: :smtp,
                 message_id: @message_id,
                 date: @date
               )

      refute inspect(error) =~ envelope.text
    end
  end

  test "requires stable caller-supplied rendering inputs" do
    assert {:error, %Error{reason: :invalid_rfc_message}} =
             RfcMessage.render(@envelope, provider: :gmail, message_id: @message_id)

    assert {:error, %Error{reason: :invalid_rfc_message}} =
             RfcMessage.render(@envelope, provider: :gmail, date: @date)

    assert {:error, %Error{reason: :invalid_rfc_message}} =
             RfcMessage.render(@envelope,
               provider: :resend,
               message_id: @message_id,
               date: @date
             )
  end

  test "rejects unsafe or dot-invalid Message-ID atoms in every message ID header" do
    invalid_ids = [
      "<left,right@example.net>",
      "<.left@example.net>",
      "<left.@example.net>",
      "<left..middle@example.net>",
      "<left@.example.net>",
      "<left@example.net.>",
      "<left@example..net>",
      "<left(comment)@example.net>",
      "<\"left\"@example.net>",
      "<<left@example.net>>",
      "<@example.net>",
      "<left@>"
    ]

    for invalid_id <- invalid_ids do
      assert_invalid(message_id: invalid_id)
      assert_invalid(envelope: %{@envelope | in_reply_to: invalid_id})
      assert_invalid(envelope: %{@envelope | references: [invalid_id]})
    end
  end

  test "accepts reasonable external dot-atom Message-IDs" do
    external_id = "<part_1+tag.more/segments=?@mx-1.example.net>"
    envelope = %{@envelope | in_reply_to: external_id, references: [external_id]}

    assert {:ok, raw} =
             RfcMessage.render(envelope,
               provider: :gmail,
               message_id: external_id,
               date: @date
             )

    assert raw =~ "Message-ID: #{external_id}\r\n"
    assert raw =~ "In-Reply-To: #{external_id}\r\n"
    assert raw =~ "References: #{external_id}\r\n"
  end

  test "enforces direct Message-ID header hard limits at 998 octets" do
    accepted_message_id = message_id_with_size(986)
    rejected_message_id = message_id_with_size(987)

    assert {:ok, raw} =
             RfcMessage.render(@envelope,
               provider: :smtp,
               message_id: accepted_message_id,
               date: @date
             )

    assert raw =~ "Message-ID: #{accepted_message_id}\r\n"
    assert_invalid(message_id: rejected_message_id)

    accepted_reply_id = message_id_with_size(985)
    rejected_reply_id = message_id_with_size(986)

    assert {:ok, raw} =
             RfcMessage.render(%{@envelope | in_reply_to: accepted_reply_id},
               provider: :smtp,
               message_id: @message_id,
               date: @date
             )

    assert raw =~ "In-Reply-To: #{accepted_reply_id}\r\n"
    assert_invalid(envelope: %{@envelope | in_reply_to: rejected_reply_id})
  end

  test "folds indivisible References tokens and rejects oversized first or later tokens" do
    largest_reference = message_id_with_size(997)
    oversized_reference = message_id_with_size(998)

    assert {:ok, raw} =
             RfcMessage.render(%{@envelope | references: [largest_reference]},
               provider: :gmail,
               message_id: @message_id,
               date: @date
             )

    assert raw =~ "References:\r\n #{largest_reference}\r\n"
    assert_invalid(envelope: %{@envelope | references: [oversized_reference]})

    assert_invalid(
      envelope: %{@envelope | references: ["<first@example.net>", oversized_reference]}
    )
  end

  test "never emits a header or encoded body line over 998 octets" do
    envelope = %{
      @envelope
      | from: "#{String.duplicate("界", 400)} <sender@example.com>",
        subject: String.duplicate("进展", 400),
        in_reply_to: message_id_with_size(985),
        references: [message_id_with_size(997)],
        text: String.duplicate("世界", 500)
    }

    assert {:ok, raw} =
             RfcMessage.render(envelope,
               provider: :gmail,
               message_id: message_id_with_size(986),
               date: @date
             )

    assert Enum.all?(String.split(raw, "\r\n"), &(byte_size(&1) <= 998))
  end

  test "folds large address lists between mailboxes while preserving syntax and order" do
    to = Enum.map(1..50, &long_address/1)
    cc = Enum.map(51..100, &long_address/1)
    bcc = Enum.map(101..150, &long_address/1)
    envelope = %{@envelope | to: to, cc: cc, bcc: bcc}
    gmail_opts = [provider: :gmail, message_id: @message_id, date: @date]
    smtp_opts = [provider: :smtp, message_id: @message_id, date: @date]

    gmail_raw = RfcMessage.render!(envelope, gmail_opts)
    smtp_raw = RfcMessage.render!(envelope, smtp_opts)

    assert unfold_header(gmail_raw, "To") == "To: " <> Enum.join(to, ", ")
    assert unfold_header(gmail_raw, "Cc") == "Cc: " <> Enum.join(cc, ", ")
    assert unfold_header(gmail_raw, "Bcc") == "Bcc: " <> Enum.join(bcc, ", ")
    assert unfold_header(smtp_raw, "To") == "To: " <> Enum.join(to, ", ")
    assert unfold_header(smtp_raw, "Cc") == "Cc: " <> Enum.join(cc, ", ")
    assert unfold_header(smtp_raw, "Bcc") == nil

    assert gmail_raw == RfcMessage.render!(envelope, gmail_opts)
    assert smtp_raw == RfcMessage.render!(envelope, smtp_opts)
    assert Enum.all?(header_lines(gmail_raw), &(byte_size(&1) <= 998))
    assert Enum.all?(header_lines(smtp_raw), &(byte_size(&1) <= 998))
  end

  test "accepts safe no-fold domain literals only for external reply IDs" do
    for external_id <- ["<id@[127.0.0.1]>", "<id@[IPv6:2001:db8::1]>"] do
      envelope = %{@envelope | in_reply_to: external_id, references: [external_id]}

      assert {:ok, raw} =
               RfcMessage.render(envelope,
                 provider: :gmail,
                 message_id: @message_id,
                 date: @date
               )

      assert raw =~ "In-Reply-To: #{external_id}\r\n"
      assert raw =~ "References: #{external_id}\r\n"
      assert_invalid(message_id: external_id)
    end
  end

  test "rejects unsafe no-fold domain literals in reply headers" do
    invalid_ids = [
      "<id@[127.0.0.1]extra>",
      "<id@[[127.0.0.1]]>",
      "<id@[127.0.0.1\\evil]>",
      "<id@[bad,comma]>",
      "<id@[bad space]>",
      "<id@[bad\tspace]>",
      "<id@[127.0.0.1]>\r\nX-Test: injected"
    ]

    for invalid_id <- invalid_ids do
      assert_invalid(envelope: %{@envelope | in_reply_to: invalid_id})
      assert_invalid(envelope: %{@envelope | references: [invalid_id]})
    end
  end

  test "quoted-printable body lines stay within 76 octets and round-trip CRLF and trailing WSP" do
    text =
      String.duplicate("界", 80) <>
        " trailing space \rline with tab\t\n\r\n.leading dot\nfinal"

    raw =
      RfcMessage.render!(%{@envelope | text: text},
        provider: :smtp,
        message_id: @message_id,
        date: @date
      )

    [_headers, encoded_body] = String.split(raw, "\r\n\r\n", parts: 2)

    assert Enum.all?(String.split(encoded_body, "\r\n"), &(byte_size(&1) <= 76))
    assert encoded_body =~ "trailing space=20\r\n"
    assert encoded_body =~ "line with tab=09\r\n"

    assert Mail.Encoders.QuotedPrintable.decode(encoded_body) ==
             String.duplicate("界", 80) <>
               " trailing space \r\nline with tab\t\r\n\r\n.leading dot\r\nfinal\r\n"
  end

  defp assert_invalid(opts) do
    envelope = Keyword.get(opts, :envelope, @envelope)
    message_id = Keyword.get(opts, :message_id, @message_id)

    assert {:error, %Error{reason: :invalid_rfc_message, details: %{}}} =
             RfcMessage.render(envelope,
               provider: :gmail,
               message_id: message_id,
               date: @date
             )
  end

  defp message_id_with_size(size) when size >= 10 do
    "<#{String.duplicate("a", size - 10)}@example>"
  end

  defp long_address(index) do
    suffix = index |> Integer.to_string() |> String.pad_leading(3, "0")
    "#{String.duplicate("a", 57)}#{suffix}@mailbox.example.net"
  end

  defp unfold_header(raw, name) do
    lines = header_lines(raw)

    case Enum.split_while(lines, &(!String.starts_with?(&1, name <> ":"))) do
      {_before, []} ->
        nil

      {_before, [first | rest]} ->
        continuations = Enum.take_while(rest, &String.starts_with?(&1, [" ", "\t"]))
        Enum.join([first | continuations], "\r\n") |> String.replace(~r/\r\n[ \t]+/, " ")
    end
  end

  defp header_lines(raw) do
    [headers, _body] = String.split(raw, "\r\n\r\n", parts: 2)
    String.split(headers, "\r\n")
  end
end
