# frozen_string_literal: true

require "spec_helper"

describe FeatureAnnouncementCampaign do
  describe "validations" do
    it "accepts only a known audience" do
      expect(build(:feature_announcement_campaign, audience: "everyone")).not_to be_valid
      expect(build(:feature_announcement_campaign, audience: "piracy_reports")).to be_valid
    end

    it "accepts only a Gumroad Reply-To address" do
      expect(build(:feature_announcement_campaign, reply_to: "someone@example.com")).not_to be_valid
      expect(build(:feature_announcement_campaign, reply_to: "support@gumroad.com")).to be_valid
    end

    it "accepts only a lowercase key" do
      expect(build(:feature_announcement_campaign, key: "New Campaign")).not_to be_valid
      expect(build(:feature_announcement_campaign, key: "new_campaign")).to be_valid
    end

    it "allows copy changes on a draft" do
      campaign = create(:feature_announcement_campaign, :draft)

      expect(campaign.update(subject: "Changed", body: "<p>Changed</p>", reply_to: "help@gumroad.com")).to be(true)
    end

    it "refuses copy changes after approval" do
      campaign = create(:feature_announcement_campaign, :draft)
      campaign.update!(state: "approved")

      expect(campaign.update(subject: "Changed", body: "<p>Changed</p>", reply_to: "help@gumroad.com")).to be(false)
      expect(campaign.errors.attribute_names).to contain_exactly(:subject, :body, :reply_to)
    end
  end

  describe "#deliverable?" do
    it "is true while sending or sent with the approved copy" do
      expect(build(:feature_announcement_campaign, state: "sending")).to be_deliverable
      expect(build(:feature_announcement_campaign, state: "sent")).to be_deliverable
    end

    it "is false before sending starts or after a cancel" do
      %w[draft approved cancelled].each do |state|
        expect(build(:feature_announcement_campaign, state:)).not_to be_deliverable
      end
    end

    it "is false when the copy no longer matches the approved digest" do
      expect(build(:feature_announcement_campaign, content_digest: nil)).not_to be_deliverable
      expect(build(:feature_announcement_campaign).tap { _1.subject = "Changed" }).not_to be_deliverable
    end
  end
end
