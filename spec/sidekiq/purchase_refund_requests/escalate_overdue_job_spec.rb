# frozen_string_literal: true

require "spec_helper"

describe PurchaseRefundRequests::EscalateOverdueJob do
  let(:seller) { create(:user) }
  let(:product) { create(:product, user: seller) }

  def create_request(created_at:, **attributes)
    travel_to(created_at) { create(:purchase_refund_request, purchase: create(:purchase, link: product), **attributes) }
  end

  before do
    Feature.activate_user(:buyer_refund_requests, seller)
    # Monday noon: a request from the previous Wednesday is past its deadline, one from Friday is not.
    travel_to(Time.utc(2026, 11, 9, 12))
  end

  it "escalates only unrefunded, undisputed requests past their deadline" do
    overdue = create_request(created_at: Time.utc(2026, 11, 4, 12))
    create_request(created_at: Time.utc(2026, 11, 6, 12))
    create_request(created_at: Time.utc(2026, 11, 4, 12)).purchase.update!(stripe_refunded: true)
    create_request(created_at: Time.utc(2026, 11, 4, 12)).purchase.update!(chargeback_date: Time.current)
    already = create_request(created_at: Time.utc(2026, 11, 4, 12), escalated_at: 1.day.ago)

    expect { described_class.new.perform }.to change { ActionMailer::Base.deliveries.count }.by(1)

    expect(overdue.reload.escalated_at).to be_present
    expect(PurchaseRefundRequest.where.not(escalated_at: nil).pluck(:id)).to contain_exactly(overdue.id, already.id)
  end

  it "still escalates an old request once the seller's flag comes back on" do
    request = create_request(created_at: 45.days.ago)
    Feature.deactivate_user(:buyer_refund_requests, seller)
    described_class.new.perform
    expect(request.reload.escalated_at).to be_nil

    Feature.activate_user(:buyer_refund_requests, seller)
    described_class.new.perform
    expect(request.reload.escalated_at).to be_present
  end

  it "skips sellers whose flag is off" do
    request = create_request(created_at: Time.utc(2026, 11, 4, 12))
    Feature.deactivate_user(:buyer_refund_requests, seller)

    described_class.new.perform

    expect(request.reload.escalated_at).to be_nil
  end

  it "keeps going when one escalation fails, and retries it on the next run" do
    failing = create_request(created_at: Time.utc(2026, 11, 4, 12))
    other = create_request(created_at: Time.utc(2026, 11, 4, 12))
    failed_once = false
    allow_any_instance_of(PurchaseRefundRequest).to receive(:escalate!).and_wrap_original do |original|
      if original.receiver.id == failing.id && !failed_once
        failed_once = true
        raise "SMTP down"
      end

      original.call
    end

    described_class.new.perform
    expect([failing, other].map { _1.reload.escalated_at.present? }).to eq([false, true])

    described_class.new.perform
    expect(failing.reload.escalated_at).to be_present
  end

  it "is scheduled" do
    schedule = YAML.load_file(Rails.root.join("config/sidekiq_schedule.yml"))
    expect(schedule.values.map { _1["class"] }).to include(described_class.name)
  end
end
