# frozen_string_literal: true

require "spec_helper"

describe PurchaseRefundRequests::EscalateWorker do
  let(:purchase) { create(:purchase) }
  let(:refund_request) { create(:purchase_refund_request, purchase:) }

  it "expires a still-open request and notifies support" do
    expect do
      described_class.new.perform(refund_request.id)
    end.to change { ActionMailer::Base.deliveries.count }.by(1)

    expect(refund_request.reload.state).to eq("expired")
    expect(ActionMailer::Base.deliveries.last.body.encoded).to include("did not respond")
  end

  it "does nothing when the request was already resolved" do
    refund_request.update!(state: "refunded")

    expect do
      described_class.new.perform(refund_request.id)
    end.not_to change { ActionMailer::Base.deliveries.count }
    expect(refund_request.reload.state).to eq("refunded")
  end

  it "does nothing for a deleted request" do
    expect do
      described_class.new.perform(-1)
    end.not_to change { ActionMailer::Base.deliveries.count }
  end
end
