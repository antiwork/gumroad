# frozen_string_literal: true

require "spec_helper"

# FeatureAnnouncementMailer renders on a worker whose reads land on a replica. The handoff gate
# compares the copy against the primary, so a render from older copy would be skipped for good.
describe "mysql2 proxy feature announcement routing" do
  include_context "real mysql2 proxy pools"

  it "renders the campaign copy from the primary" do
    user = primary_setup { create(:user, email: "routing-creator@example.com") }
    primary_setup { replicate_record(user) }
    primary_setup { create(:feature_announcement_campaign, key: "routing_campaign", subject: "Primary copy") }

    message = nil
    reads = record_serving_reads do
      message = FeatureAnnouncementMailer.announcement(campaign: "routing_campaign", user_id: user.id, email: user.email).message
    end

    campaign_reads = reads.select { |sql, _| sql.include?("`feature_announcement_campaigns`") }
    expect(campaign_reads.map(&:last).uniq).to eq(["primary"])
    expect(message.subject).to eq("Primary copy")
    expect(serving_pool).to eq("replica")
  end

  it "starts a send the replica has not seen yet" do
    campaign = primary_setup { create(:feature_announcement_campaign, key: "routing_send", state: "sending") }
    user = primary_setup do
      create(:user, email: "routing-subscriber@example.com").tap do
        FeatureAnnouncementSubscription.update_from_settings!(_1, subscribed: true, rendered_version: 0)
      end
    end

    reads = record_serving_reads { SendFeatureAnnouncementCampaignJob.new.perform(campaign.id) }

    recipient_reads = reads.select { |sql, _| sql.match?(/`(feature_announcement_subscriptions|users)`/) }
    expect(recipient_reads.map(&:last).uniq).to eq(["primary"])
    expect(ActiveJob::Base.queue_adapter.enqueued_jobs.map { _1["arguments"].last["args"].first["user_id"] }).to include(user.id)
    expect(primary_setup { campaign.reload.state }).to eq("sent")
  end
end
