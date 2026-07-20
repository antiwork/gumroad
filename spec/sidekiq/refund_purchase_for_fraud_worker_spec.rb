# frozen_string_literal: true

require "spec_helper"

describe RefundPurchaseForFraudWorker do
  let!(:gumroad_merchant_account) { create(:merchant_account, user: nil) }
  let(:admin_user) { create(:admin_user) }
  let(:user) { create(:compliant_user, user_risk_state: "suspended_for_fraud") }
  let(:product) { create(:product, user:) }

  it "retries per purchase" do
    expect(described_class.sidekiq_options["retry"]).to eq(5)
  end

  it "refunds without blocking the buyer by default" do
    purchase = create(:purchase, seller: user, link: product, stripe_transaction_id: "ch_test")

    expect_any_instance_of(Purchase).to receive(:refund_for_fraud!).with(admin_user.id, skip_already_refunded: true).and_return(true)
    expect_any_instance_of(Purchase).not_to receive(:block_buyer!)

    described_class.new.perform(purchase.id, admin_user.id, false)
  end

  it "refunds and blocks the buyer when block_buyers is true" do
    purchase = create(:purchase, seller: user, link: product, stripe_transaction_id: "ch_test")

    expect_any_instance_of(Purchase).to receive(:refund_for_fraud_and_block_buyer!).with(admin_user.id, skip_already_refunded: true).and_return(true)

    described_class.new.perform(purchase.id, admin_user.id, true)
  end

  # Deliberately unstubbed: exercises the real refund primitives against an
  # already-refunded purchase (the race where a concurrent refund won). The nil
  # return from refund_and_save! must be treated as a clean skip — no exception,
  # no buyer blocking, no subscription side effects.
  it "treats an already-refunded purchase as a clean skip without blocking the buyer" do
    purchase = create(:purchase, seller: user, link: product, stripe_transaction_id: "ch_test", stripe_refunded: true)

    expect(ErrorNotifier).not_to receive(:notify)
    expect do
      described_class.new.perform(purchase.id, admin_user.id, true)
    end.not_to change { BlockedObject.count }
  end

  it "notifies and re-raises when the refund fails so Sidekiq retries" do
    purchase = create(:purchase, seller: user, link: product, stripe_transaction_id: "ch_test")

    allow_any_instance_of(Purchase).to receive(:refund_for_fraud!) do |instance|
      instance.errors.add :base, "Refund amount cannot be greater than the purchase price."
      false
    end

    expect(ErrorNotifier).to receive(:notify).and_call_original

    expect do
      described_class.new.perform(purchase.id, admin_user.id, false)
    end.to raise_error(/Refund amount cannot be greater than the purchase price/)
  end

  it "notifies and re-raises on unexpected exceptions" do
    purchase = create(:purchase, seller: user, link: product, stripe_transaction_id: "ch_test")

    allow_any_instance_of(Purchase).to receive(:refund_for_fraud!).and_raise(StandardError, "Stripe is unavailable")

    expect(ErrorNotifier).to receive(:notify).and_call_original

    expect do
      described_class.new.perform(purchase.id, admin_user.id, false)
    end.to raise_error(StandardError, "Stripe is unavailable")
  end
end
