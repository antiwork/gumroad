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

  describe "transitions" do
    let(:approver) { create(:admin_user) }
    let(:campaign) { create(:feature_announcement_campaign, :draft) }

    it "approves a draft with the digest of its current copy" do
      campaign.approve!(by: approver, digest: campaign.current_digest)

      expect(campaign.reload).to have_attributes(state: "approved", approved_by: approver, content_digest: campaign.current_digest)
    end

    it "refuses an approval for older copy or a second approval" do
      expect { campaign.approve!(by: approver, digest: "stale") }.to raise_error(described_class::InvalidTransition)

      campaign.approve!(by: approver, digest: campaign.current_digest)
      expect { campaign.approve!(by: approver, digest: campaign.current_digest) }.to raise_error(described_class::InvalidTransition)
    end

    it "starts sending only an approved campaign" do
      expect { campaign.start_sending! }.to raise_error(described_class::InvalidTransition)

      campaign.approve!(by: approver, digest: campaign.current_digest)
      campaign.start_sending!

      expect(campaign.reload.state).to eq("sending")
      expect(SendFeatureAnnouncementCampaignJob.jobs.map { _1["args"] }).to eq([[campaign.id]])
    end

    it "sends a campaign that is already sending again" do
      sending = create(:feature_announcement_campaign, state: "sending")

      sending.start_sending!

      expect(SendFeatureAnnouncementCampaignJob.jobs.map { _1["args"] }).to eq([[sending.id]])
    end

    it "cancels a campaign in any state but cancelled" do
      campaign.cancel!
      expect(campaign.reload.state).to eq("cancelled")
      expect { campaign.cancel! }.to raise_error(described_class::InvalidTransition)

      sent = create(:feature_announcement_campaign, state: "sent")
      sent.cancel!
      expect(sent.reload.state).to eq("cancelled")
    end
  end

  it "refuses a link that is not https" do
    expect(build(:feature_announcement_campaign, body: '<a href="http://example.com">x</a>')).not_to be_valid
    expect(build(:feature_announcement_campaign, body: '<a href="https://example.com">x</a>')).to be_valid
  end
end
