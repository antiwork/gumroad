# frozen_string_literal: true

require "spec_helper"

describe SupportContactMailer do
  def build(category: "payouts", email: "buyer@example.com")
    described_class.contact_form(
      email:,
      category:,
      message: "My payout hasn't arrived and it's been over a week now."
    )
  end

  describe "contact_form" do
    it "addresses the support inbox and replies to the submitter" do
      mail = build

      expect(mail.to).to eq([ApplicationMailer::SUPPORT_EMAIL])
      expect(mail.reply_to).to eq(["buyer@example.com"])
    end

    it "keeps the category in the subject so existing triage still matches" do
      expect(build(category: "purchases & refunds").subject)
        .to start_with("Help Center contact form: purchases & refunds")
    end

    it "names the submitter in the subject" do
      expect(build(email: "seller@example.com").subject).to include("seller@example.com")
    end

    it "gives every submission its own subject" do
      subjects = Array.new(3) { build.subject }

      expect(subjects.uniq.size).to eq(3)
      expect(subjects).to all(include("Help Center contact form: payouts"))
    end

    it "differs per submission even for the same submitter and category" do
      first = build(email: "repeat@example.com").subject
      second = build(email: "repeat@example.com").subject

      expect(first).not_to eq(second)
    end

    it "carries no threading headers, so nothing can pull it into an existing thread" do
      mail = build

      expect(mail["In-Reply-To"]).to be_nil
      expect(mail["References"]).to be_nil
    end

    it "mints a distinct Message-ID per submission" do
      # Mail only adds the Message-ID in ready_to_send!, i.e. at delivery.
      ids = Array.new(3) do
        mail = build
        mail.message.ready_to_send!
        mail.message_id
      end

      expect(ids.uniq.size).to eq(3)
      expect(ids).to all(be_present)
    end

    context "with image attachments" do
      let(:png_bytes) { Base64.decode64("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==") }

      def build_with_attachments(filenames)
        described_class.contact_form(
          email: "buyer@example.com",
          category: "technical issue",
          message: "The checkout button does nothing.",
          attachments: filenames.map { |filename| { filename:, mime_type: "image/png", content: Base64.strict_encode64(png_bytes) } }
        )
      end

      it "attaches the decoded bytes with the image's MIME type" do
        mail = build_with_attachments(["checkout.png"])

        expect(mail.attachments.size).to eq(1)
        attachment = mail.attachments.first
        expect(attachment.filename).to eq("checkout.png")
        expect(attachment.content_type).to start_with("image/png")
        expect(attachment.body.decoded).to eq(png_bytes)
      end

      it "counts the attachments in the body so support sees them even without opening the files" do
        mail = build_with_attachments(["checkout.png", "console.png"])
        body = mail.html_part ? mail.html_part.decoded : mail.body.decoded

        expect(body).to include("Attachments: 2")
        expect(body).to include("checkout.png", "console.png")
      end

      it "rebuilds a hostile upload name instead of trusting it" do
        mail = build_with_attachments(['"../../evil.exe".png'])

        expect(mail.attachments.first.filename).to eq("evil_exe_.png")
      end

      it "keeps the email attachment-free when nothing was uploaded" do
        expect(build.attachments).to be_empty
      end

      it "names repeated uploads apart instead of sending several files with one name" do
        mail = build_with_attachments(["image.png", "image.png", "image.png"])

        expect(mail.attachments.map(&:filename)).to eq(["image.png", "image-2.png", "image-3.png"])
        body = mail.html_part ? mail.html_part.decoded : mail.body.decoded
        expect(body).to include("image.png, image-2.png, image-3.png")
      end

      it "drops whatever extension the upload name claims" do
        mail = build_with_attachments(["archive.gz", "notes.txt.zip"])

        expect(mail.attachments.map(&:filename)).to eq(["archive.png", "notes_txt.png"])
      end
    end

    context "with the largest submission the form accepts" do
      let(:screenshots) { Array.new(2) { "\x89PNG\r\n\x1A\n".b + Random.bytes(HelpCenter::ContactsController::MAX_ATTACHMENT_BYTES - 8) } }
      let(:encoded) { screenshots.map { Base64.strict_encode64(_1) } }

      def deliver_with(email_provider)
        options = MailerInfo::DeliveryMethod.options(domain: :gumroad, email_provider:)
        allow(MailerInfo).to receive(:random_delivery_method_options).and_return(options)

        described_class.contact_form(
          email: "buyer@example.com",
          category: "technical issue",
          message: "a" * HelpCenter::ContactsController::MAX_MESSAGE_LENGTH,
          attachments: encoded.map { { filename: "image.png", mime_type: "image/png", content: _1 } }
        ).message
      end

      it "keeps the SendGrid header inside the provider's custom-args limit" do
        mail = deliver_with(MailerInfo::EMAIL_PROVIDER_SENDGRID)
        header = mail.header[MailerInfo::SENDGRID_X_SMTPAPI_HEADER].value

        expect(header.bytesize).to be < 10_000
        expect(header).not_to include(encoded.first.first(64))
        expect(JSON.parse(header).dig("unique_args", "mailer_args")).to include("attachments")
        expect(mail.attachments.map { _1.body.decoded }).to eq(screenshots)
      end

      it "keeps the image bytes out of the encrypted Resend header" do
        mail = deliver_with(MailerInfo::EMAIL_PROVIDER_RESEND)
        mailer_args = MailerInfo.decrypt(mail.header[MailerInfo.header_name(:mailer_args)].value)

        expect(mailer_args.bytesize).to be < 1_000
        expect(mailer_args).not_to include(encoded.first.first(64))
        expect(mail.attachments.map { _1.body.decoded }).to eq(screenshots)
      end
    end
  end
end
