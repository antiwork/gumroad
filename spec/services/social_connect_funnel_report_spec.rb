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
      record(connected_seller, "hold_released", "twitter", "mark_compliant", at: 3.hours.ago)
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
      expect(held[:connected][:time_to_hold_released_hours][:p50]).to eq(7.0)
      expect(held[:connected][:time_to_first_payout_hours][:p50]).to eq(8.0)
      expect(held[:connected][:still_held]).to eq(0)
      expect(held[:unconnected][:n]).to eq(1)
      expect(held[:unconnected][:time_to_review_hours]).to be_nil
      expect(held[:unconnected][:still_unreviewed]).to eq(1)
      expect(held[:unconnected][:still_held]).to eq(1)
      expect(held[:unconnected][:still_unpaid]).to eq(1)
    end
  end

  it "uses the earliest completed payout on or after the offer, not a historical one" do
    freeze_time do
      record(skipped_seller, "offered", "twitter", "account_review", at: 10.hours.ago)
      create(:payment_completed, user: skipped_seller, created_at: 12.hours.ago)
      create(:payment_completed, user: skipped_seller, created_at: 2.hours.ago)

      held = described_class.new(since: 1.day.ago).to_h[:held_sellers][:unconnected]
      expect(held[:still_unpaid]).to eq(0)
      expect(held[:time_to_first_payout_hours][:p50]).to eq(8.0)
    end
  end

  it "matches funnel stages in chronological order" do
    freeze_time do
      record(skipped_seller, "attempted", "twitter", "omniauth", at: 12.hours.ago)
      record(skipped_seller, "offered", "twitter", "account_review", at: 10.hours.ago)
      record(connected_seller, "connected", "youtube", "omniauth", at: 12.hours.ago)
      record(connected_seller, "attempted", "youtube", "omniauth", at: 10.hours.ago)

      data = described_class.new(since: 1.day.ago).to_h
      expect(data[:per_provider]["twitter"][:skipped_unattempted]).to eq(1)
      expect(data[:per_provider]["twitter"][:abandonment_rate]).to eq(1.0)
      expect(data[:per_provider]["youtube"][:failure_rate]).to eq(1.0)
    end
  end

  it "ignores reviews that happened before the offer" do
    freeze_time do
      record(skipped_seller, "reviewed", "twitter", "admin_social_connections", at: 12.hours.ago)
      record(skipped_seller, "offered", "twitter", "account_review", at: 10.hours.ago)

      held = described_class.new(since: 1.day.ago).to_h[:held_sellers][:unconnected]
      expect(held[:still_unreviewed]).to eq(1)
      expect(held[:time_to_review_hours]).to be_nil
    end
  end

  it "counts later suspensions from risk-state comments, not current user_risk_state" do
    freeze_time do
      restored = create(:user, user_risk_state: "compliant")
      already_suspended = create(:user, user_risk_state: "suspended_for_fraud")
      record(restored, "connected", "twitter", "omniauth", at: 8.hours.ago)
      record(already_suspended, "connected", "youtube", "omniauth", at: 8.hours.ago)
      create(:comment, commentable: restored, comment_type: Comment::COMMENT_TYPE_SUSPENDED, created_at: 2.hours.ago)
      create(:comment, commentable: already_suspended, comment_type: Comment::COMMENT_TYPE_SUSPENDED, created_at: 12.hours.ago)

      adverse = described_class.new(since: 1.day.ago).to_h[:adverse_outcomes]
      expect(adverse[:connected_users]).to eq(2)
      expect(adverse[:later_suspensions]).to eq(1)
    end
  end

  it "counts a seller with a post-connect chargeback even when an earlier chargeback exists" do
    freeze_time do
      later = create(:purchase)
      later.update_column(:chargeback_date, 2.hours.ago)
      earlier_same_seller = create(:purchase, link: later.link, seller: later.seller, stripe_transaction_id: "txn-earlier-same")
      earlier_same_seller.update_column(:chargeback_date, 12.hours.ago)
      record(later.seller, "connected", "twitter", "omniauth", at: 8.hours.ago)
      earlier_only = create(:purchase, stripe_transaction_id: "txn-earlier-only")
      earlier_only.update_column(:chargeback_date, 12.hours.ago)
      record(earlier_only.seller, "connected", "youtube", "omniauth", at: 8.hours.ago)

      adverse = described_class.new(since: 1.day.ago).to_h[:adverse_outcomes]
      expect(adverse[:later_chargeback_sellers]).to eq(1)
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
