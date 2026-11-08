# frozen_string_literal: true

require "spec_helper"

describe PurchaseRefundRequests::NotifyWorker do
  let(:purchase) { create(:purchase) }
  let(:refund_request) { create(:purchase_refund_request, purchase:, message: "The files were corrupted.") }

  before do
    Feature.activate_user(:buyer_refund_requests, purchase.seller)
  end

  it "delivers both notifications and stamps them" do
    expect do
      described_class.new.perform(refund_request.id)
    end.to change { ActionMailer::Base.deliveries.count }.by(2)

    refund_request.reload
    expect(refund_request.seller_notified_at).to be_present
    expect(refund_request.support_notified_at).to be_present

    seller_mail = ActionMailer::Base.deliveries.find { |mail| mail.to == [purchase.seller.email] }
    expect(seller_mail.subject).to eq("A customer has requested a refund")
  end

  it "is idempotent: a second run delivers nothing" do
    described_class.new.perform(refund_request.id)

    expect do
      described_class.new.perform(refund_request.id)
    end.not_to change { ActionMailer::Base.deliveries.count }
  end

  it "delivers only the missing notification on retry after a partial failure" do
    refund_request.update_column(:seller_notified_at, Time.current)

    expect do
      described_class.new.perform(refund_request.id)
    end.to change { ActionMailer::Base.deliveries.count }.by(1)

    expect(refund_request.reload.support_notified_at).to be_present
  end

  it "does nothing when the flag was turned off after enqueue" do
    Feature.deactivate_user(:buyer_refund_requests, purchase.seller)

    expect do
      described_class.new.perform(refund_request.id)
    end.not_to change { ActionMailer::Base.deliveries.count }
    expect(refund_request.reload.seller_notified_at).to be_nil
  end

  it "does nothing for a closed request" do
    refund_request.update!(state: "declined")

    expect do
      described_class.new.perform(refund_request.id)
    end.not_to change { ActionMailer::Base.deliveries.count }
  end

  it "does nothing for a deleted request" do
    expect do
      described_class.new.perform(-1)
    end.not_to change { ActionMailer::Base.deliveries.count }
  end
end
