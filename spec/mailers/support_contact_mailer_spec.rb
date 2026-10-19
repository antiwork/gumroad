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
    end
  end
end
