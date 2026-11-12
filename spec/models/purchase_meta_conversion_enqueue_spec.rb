# frozen_string_literal: true

require "spec_helper"

describe Purchase, "Meta conversion enqueue" do
  let(:purchase) { create(:purchase, purchase_state: "in_progress") }

  before do
    MerchantAccount.find_or_create_by!(user_id: nil, charge_processor_id: StripeChargeProcessor.charge_processor_id) do |merchant_account|
      merchant_account.charge_processor_alive_at = Time.current
    end
  end

  it "enqueues the sender once the purchase succeeds" do
    purchase.mark_successful!

    expect(SendMetaConversionEventJob).to have_enqueued_sidekiq_job(purchase.id)
  end

  it "enqueues nothing for a purchase that does not succeed" do
    purchase.mark_failed!

    expect(SendMetaConversionEventJob).not_to have_enqueued_sidekiq_job(purchase.id)
  end

  it "does not fail the purchase when the queue is unreachable" do
    allow(SendMetaConversionEventJob).to receive(:perform_async).and_raise(Redis::CannotConnectError)
    allow(Rails.logger).to receive(:error)

    expect { purchase.mark_successful! }.not_to raise_error
    expect(purchase.reload).to be_successful
    expect(Rails.logger).to have_received(:error).with(/Failed to enqueue the Meta conversion event for purchase_id=#{purchase.id}/)
  end
end
