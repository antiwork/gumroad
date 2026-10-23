# frozen_string_literal: true

require "spec_helper"

describe SendFeatureAnnouncementCampaignJob do
  include ActiveJob::TestHelper

  let!(:campaign) { create(:feature_announcement_campaign, key: "new_feature", state: "sending") }

  def subscribed_seller(email)
    create_piracy_seller_with_product.first.tap do
      _1.update_columns(email:)
      FeatureAnnouncementSubscription.update_from_settings!(_1, subscribed: true, rendered_version: 0)
    end
  end

  before { ActionMailer::Base.deliveries.clear }

  it "sends to opted-in accounts in the audience and marks the campaign sent" do
    seller = subscribed_seller("seller@example.com")
    outside = create(:user, email: "buyer@example.com").tap { FeatureAnnouncementSubscription.update_from_settings!(_1, subscribed: true, rendered_version: 0) }
    opted_out = subscribed_seller("opted-out@example.com").tap { FeatureAnnouncementSubscription.unsubscribe!(_1, source: "settings") }

    perform_enqueued_jobs { described_class.new.perform(campaign.id) }

    expect(ActionMailer::Base.deliveries.map(&:to)).to eq([["seller@example.com"]])
    expect(FeatureAnnouncementDelivery.where(campaign: "new_feature").pluck(:user_id, :state, :reason)).to contain_exactly(
      [seller.id, "delivered", nil], [outside.id, "skipped", "not_in_audience"]
    )
    expect(FeatureAnnouncementDelivery.where(user_id: opted_out.id)).to be_empty
    expect(campaign.reload.state).to eq("sent")
  end

  it "continues after the last subscription of a full batch" do
    stub_const("#{described_class}::BATCH_SIZE", 1)
    first = subscribed_seller("first@example.com")
    subscribed_seller("second@example.com")

    described_class.new.perform(campaign.id)

    expect(enqueued_jobs.size).to eq(1)
    expect(described_class.jobs.map { _1["args"] }).to eq([[campaign.id, FeatureAnnouncementSubscription.find_by!(user_id: first.id).id]])
    expect(campaign.reload.state).to eq("sending")
  end

  it "enqueues nothing once the campaign is cancelled" do
    subscribed_seller("seller@example.com")
    campaign.update!(state: "cancelled")

    described_class.new.perform(campaign.id)

    expect(enqueued_jobs).to be_empty
    expect(campaign.reload.state).to eq("cancelled")
  end

  it "skips emails still queued when the campaign is cancelled" do
    subscribed_seller("seller@example.com")
    described_class.new.perform(campaign.id)
    campaign.update_columns(state: "cancelled")

    perform_enqueued_jobs

    expect(ActionMailer::Base.deliveries).to be_empty
    expect(FeatureAnnouncementDelivery.sole.reason).to eq("campaign_not_deliverable")
  end
end
