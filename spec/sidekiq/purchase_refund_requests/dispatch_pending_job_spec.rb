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
    overdue_owed = create_request(created_at: Time.utc(2026, 11, 4, 12))
    create_request(created_at: Time.utc(2026, 11, 4, 12), state: "refunded")
    PurchaseRefundRequests::NotifyJob.jobs.clear

    described_class.new.perform

    expect(PurchaseRefundRequests::NotifyJob.jobs.map { _1["args"] }).to eq([[lost_push.id]])
    expect(PurchaseRefundRequests::EscalateJob.jobs.map { _1["args"] }).to eq([[overdue.id], [overdue_owed.id]])
    expect([recent, notified].map { _1.reload.state }).to eq(%w[requested requested])
  end

  it "keeps retrying a seller notification still owed after escalation, without a second support email" do
    seller_mail_down = true
    allow_any_instance_of(Mail::Message).to receive(:deliver).and_wrap_original do |original, *args|
      raise Net::SMTPFatalError.new("550 unavailable") if seller_mail_down && original.receiver.to == [seller.email]
      original.call(*args)
    end
    request = create_request(created_at: Time.utc(2026, 11, 4, 12))
    expect { PurchaseRefundRequests::NotifyJob.drain }.to raise_error(Net::SMTPFatalError)

    described_class.new.perform
    expect(PurchaseRefundRequests::NotifyJob.jobs.size).to eq(0)
    PurchaseRefundRequests::EscalateJob.drain
    request.reload
    expect(request.state).to eq("escalated")
    expect(request.seller_notified_at).to be_nil
    support_emails = ActionMailer::Base.deliveries.count { _1.to == [ApplicationMailer::SUPPORT_EMAIL] }

    described_class.new.perform
    expect { PurchaseRefundRequests::NotifyJob.drain }.to raise_error(Net::SMTPFatalError)

    seller_mail_down = false
    described_class.new.perform
    PurchaseRefundRequests::NotifyJob.drain

    expect(request.reload.seller_notified_at).to be_present
    expect(request.state).to eq("escalated")
    expect(ActionMailer::Base.deliveries.count { _1.to == [seller.email] }).to eq(1)
    expect(ActionMailer::Base.deliveries.count { _1.to == [ApplicationMailer::SUPPORT_EMAIL] }).to eq(support_emails)
  end

  it "re-pushes escalated requests only while the seller email is owed and inside the retry window" do
    owed = create_request(created_at: 3.days.ago, state: "escalated", support_notified_at: 1.day.ago)
    create_request(created_at: 3.days.ago, state: "escalated", seller_notified_at: 2.days.ago, support_notified_at: 1.day.ago)
    create_request(created_at: (described_class::OWED_NOTIFICATION_RETRY_WINDOW + 1.day).ago, state: "escalated", support_notified_at: 1.day.ago)
    create_request(created_at: 3.days.ago, state: "refunded")
    PurchaseRefundRequests::NotifyJob.jobs.clear

    described_class.new.perform

    expect(PurchaseRefundRequests::NotifyJob.jobs.map { _1["args"] }).to eq([[owed.id]])
  end

  it "skips sellers whose flag is off" do
    create_request(created_at: Time.utc(2026, 11, 4, 12))
    create_request(created_at: 3.days.ago, state: "escalated", support_notified_at: 1.day.ago)
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
