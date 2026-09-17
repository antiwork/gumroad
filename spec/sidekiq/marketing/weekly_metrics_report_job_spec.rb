# frozen_string_literal: true

require "spec_helper"

describe Marketing::WeeklyMetricsReportJob do
  it "writes a queryable snapshot per cohort, renders all read-outs, and is idempotent" do
    travel_to Time.utc(2026, 8, 5, 12) do
      seller = create(:user)
      create(:marketing_holdout_assignment, user: seller, marketing_holdout_assigned_at: 100.days.ago)
      2.times { described_class.new.perform }
      expect(Marketing::MetricsSnapshot.count).to eq(2)
      snapshot = Marketing::MetricsSnapshot.find_by!(cohort: "zero_sale")
      expect(snapshot.window_end).to eq(Time.utc(2026, 8, 3))
      expect(snapshot.metrics["net_revenue"]["treatment"]).to include("n" => 1, "amount_cents" => 0)
      expect(snapshot.report_text).to include("first_sale:", "repeat_purchase:", "net_revenue:", "Email safety:", "cart_recovery:", "Blocks rollout: true")
      expect(snapshot.report_text).not_to include(seller.email)
    end
  end

  it "accepts a pinned week for retries and historical reads" do
    described_class.new.perform("2026-08-03T00:00:00Z")
    expect(Marketing::MetricsSnapshot.distinct.pluck(:window_end)).to eq([Time.utc(2026, 8, 3)])
  end

  it "schedules a weekly low priority report without a Telegram dependency" do
    entry = YAML.load_file(Rails.root.join("config/sidekiq_schedule.yml")).fetch("marketing_weekly_metrics_report")
    expect(entry).to include("cron" => "0 12 * * 1", "class" => described_class.name, "queue" => "low")
  end
end
