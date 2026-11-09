# frozen_string_literal: true

require "spec_helper"

describe PurchaseRefundRequests::EscalateJob do
  let(:purchase) { create(:purchase) }
  let(:refund_request) { create(:purchase_refund_request, purchase:) }

  before do
    Feature.activate_user(:buyer_refund_requests, purchase.seller)
  end

  it "escalates a still-open request and notifies support" do
    expect do
      described_class.new.perform(refund_request.id)
    end.to change { ActionMailer::Base.deliveries.count }.by(1)

    expect(refund_request.reload.state).to eq("escalated")
    expect(ActionMailer::Base.deliveries.last.body.encoded).to include("is still open after 2 business days")
  end

  it "queues the buyer's escalation notice after escalating" do
    refund_request
    PurchaseRefundRequests::NotifyJob.jobs.clear

    described_class.new.perform(refund_request.id)

    expect(PurchaseRefundRequests::NotifyJob.jobs.map { _1["args"] }).to eq([[refund_request.id]])
  end

  it "closes the request without emailing support when the purchase was refunded but the sync missed it" do
    refund_request
    purchase.update_column(:stripe_refunded, true)

    expect do
      described_class.new.perform(refund_request.id)
    end.not_to change { ActionMailer::Base.deliveries.count }
    expect(refund_request.reload.state).to eq("refunded")
  end

  it "tells support when the seller has not been notified yet" do
    refund_request.update_columns(seller_notified_at: nil, support_notified_at: Time.current)

    described_class.new.perform(refund_request.id)

    expect(ActionMailer::Base.deliveries.last.body.encoded).to include("Seller notified: not yet (still retrying), so contact the seller directly")
  end

  it "counts the escalation email as support's notice, so no later support copy is owed" do
    refund_request.update_columns(seller_notified_at: Time.current, support_notified_at: nil, message: "The files were corrupted.")

    described_class.new.perform(refund_request.id)

    expect(ActionMailer::Base.deliveries.last.text_part.decoded.squish).to include("Message: The files were corrupted.")
    expect(refund_request.reload.support_notified_at).to be_present

    # The queued NotifyJob then owes the buyer's escalation notice only.
    expect { PurchaseRefundRequests::NotifyJob.drain }.to change { ActionMailer::Base.deliveries.count }.by(1)
    expect(ActionMailer::Base.deliveries.last.to).to eq([refund_request.email])
    expect(refund_request.reload.notifications_pending?).to eq(false)
  end

  it "tells support when the seller already refunded part of the purchase" do
    purchase.refund_partial_purchase!(purchase.total_transaction_cents / 2, purchase.seller.id)

    described_class.new.perform(refund_request.id)

    expect(ActionMailer::Base.deliveries.last.body.encoded).to include("Refunded so far: partially")
  end

  it "leaves the request open when the support email fails, so a retry sends it" do
    allow(SupportContactMailer).to receive(:contact_form).and_raise(Net::ReadTimeout)

    expect { described_class.new.perform(refund_request.id) }.to raise_error(Net::ReadTimeout)
    expect(refund_request.reload.state).to eq("requested")

    allow(SupportContactMailer).to receive(:contact_form).and_call_original
    expect do
      described_class.new.perform(refund_request.id)
    end.to change { ActionMailer::Base.deliveries.count }.by(1)
    expect(refund_request.reload.state).to eq("escalated")
  end

  it "leaves the request open when the mail server rejects the support email" do
    allow_any_instance_of(Mail::Message).to receive(:deliver).and_raise(Net::SMTPFatalError.new("550 rejected"))

    expect { described_class.new.perform(refund_request.id) }.to raise_error(Net::SMTPFatalError)
    expect(refund_request.reload.state).to eq("requested")
  end

  it "does nothing when the flag was turned off" do
    Feature.deactivate_user(:buyer_refund_requests, purchase.seller)

    expect do
      described_class.new.perform(refund_request.id)
    end.not_to change { ActionMailer::Base.deliveries.count }
    expect(refund_request.reload.state).to eq("requested")
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
