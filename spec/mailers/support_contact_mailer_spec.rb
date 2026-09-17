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
      ids = Array.new(3) { build.message_id }

      expect(ids.uniq.size).to eq(3)
      expect(ids).to all(be_present)
    end
  end
end
