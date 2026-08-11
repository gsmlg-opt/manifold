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
end
