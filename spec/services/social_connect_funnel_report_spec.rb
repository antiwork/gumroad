# frozen_string_literal: true

require "spec_helper"

describe SocialConnectFunnelReport do
  let(:connected_seller) { create(:user) }
  let(:skipped_seller) { create(:user) }

  def record(user, stage, provider, surface, at:)
    event = SocialConnectFunnel.record!(user:, stage:, provider:, surface:)
    event.update_column(:created_at, at)
    event
  end

  it "reports failure rate, abandonment, and held timing without coercing missing intervals to zero" do
    freeze_time do
      record(connected_seller, "offered", "twitter", "account_review", at: 10.hours.ago)
      record(connected_seller, "attempted", "twitter", "omniauth", at: 9.hours.ago)
      record(connected_seller, "connected", "twitter", "omniauth", at: 8.hours.ago)
      record(connected_seller, "reviewed", "twitter", "admin_social_connections", at: 4.hours.ago)
      record(skipped_seller, "offered", "twitter", "account_review", at: 10.hours.ago)

      create(:payment_completed, user: connected_seller, created_at: 2.hours.ago)

      data = described_class.new(since: 1.day.ago).to_h
      twitter = data[:per_provider]["twitter"]
      expect(twitter[:offered]).to eq(2)
      expect(twitter[:attempted]).to eq(1)
      expect(twitter[:connected]).to eq(1)
      expect(twitter[:skipped_unattempted]).to eq(1)
      expect(twitter[:abandonment_rate]).to eq(0.5)
      expect(twitter[:failure_rate]).to eq(0.0)

      held = data[:held_sellers]
      expect(held[:connected][:n]).to eq(1)
      expect(held[:connected][:time_to_review_hours][:p50]).to eq(6.0)
      expect(held[:connected][:time_to_first_payout_hours][:p50]).to eq(8.0)
      expect(held[:unconnected][:n]).to eq(1)
      expect(held[:unconnected][:time_to_review_hours]).to be_nil
      expect(held[:unconnected][:still_unreviewed]).to eq(1)
      expect(held[:unconnected][:still_unpaid]).to eq(1)
    end
  end

  it "prints a runnable text report" do
    SocialConnectFunnel.record!(user: skipped_seller, stage: "offered", provider: "youtube", surface: "getting_started")

    text = described_class.new(since: 1.hour.ago).to_text
    expect(text).to include("youtube:")
    expect(text).to include("skipped_unattempted=1")
    expect(text).to include("n/a (no completed intervals)")
  end
end
