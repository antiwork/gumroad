# frozen_string_literal: true

require "spec_helper"

describe PurchaseRefundRequests::DispatchPendingJob do
  let(:seller) { create(:user) }
  let(:product) { create(:product, user: seller) }

  def create_request(created_at:, **attributes)
    travel_to(created_at) { create(:purchase_refund_request, purchase: create(:purchase, link: product), **attributes) }
  end

  before do
    Feature.activate_user(:buyer_refund_requests, seller)
    # Monday 12:00 UTC: a request from the previous Wednesday is past its two-business-day deadline,
    # one from this morning is not.
    travel_to(Time.utc(2026, 11, 9, 12))
  end

  it "re-enqueues lost notifications and escalates requests past their deadline" do
    lost_push = create_request(created_at: 1.hour.ago)
    recent = create_request(created_at: 1.minute.ago)
    notified = create_request(created_at: 1.hour.ago, seller_notified_at: 1.hour.ago, support_notified_at: 1.hour.ago)
    overdue = create_request(created_at: Time.utc(2026, 11, 4, 12), seller_notified_at: 5.days.ago, support_notified_at: 5.days.ago)
    create_request(created_at: Time.utc(2026, 11, 4, 12), state: "refunded")
    PurchaseRefundRequests::NotifyJob.jobs.clear

    described_class.new.perform

    expect(PurchaseRefundRequests::NotifyJob.jobs.map { _1["args"] }).to eq([[lost_push.id]])
    expect(PurchaseRefundRequests::EscalateJob.jobs.map { _1["args"] }).to eq([[overdue.id]])
    expect([recent, notified].map { _1.reload.state }).to eq(%w[requested requested])
  end

  it "skips sellers whose flag is off" do
    create_request(created_at: Time.utc(2026, 11, 4, 12))
    PurchaseRefundRequests::NotifyJob.jobs.clear
    Feature.deactivate_user(:buyer_refund_requests, seller)

    described_class.new.perform

    expect(PurchaseRefundRequests::NotifyJob.jobs.size).to eq(0)
    expect(PurchaseRefundRequests::EscalateJob.jobs.size).to eq(0)
  end

  it "is scheduled" do
    schedule = YAML.load_file(Rails.root.join("config", "sidekiq_schedule.yml"))

    expect(schedule.values.map { _1["class"] }).to include(described_class.name)
  end
end
