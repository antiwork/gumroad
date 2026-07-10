# frozen_string_literal: true

require "spec_helper"

describe StripeConnectPaymentMethodAvailabilityService do
  let(:seller) { create(:user, check_merchant_account_is_linked: true) }
  let(:merchant_account) { create(:merchant_account_stripe_connect, user: seller) }
  let(:service) { described_class.new(merchant_account) }

  def stripe_account_with(capabilities)
    Stripe::Util.convert_to_stripe_object({ id: merchant_account.charge_processor_merchant_id, object: "account", capabilities: }, {})
  end

  describe "#refresh!" do
    it "persists the US-locked methods whose capabilities are active" do
      allow(Stripe::Account).to receive(:retrieve)
        .with(merchant_account.charge_processor_merchant_id)
        .and_return(stripe_account_with(cashapp_payments: "active", us_bank_account_ach_payments: "active", card_payments: "active"))

      expect(service.refresh!).to match_array(%w[cashapp us_bank_account])
      expect(merchant_account.reload.us_locked_payment_method_availability["payment_method_types"]).to match_array(%w[cashapp us_bank_account])
      expect(merchant_account.us_locked_payment_method_availability["refreshed_at"]).to be_present
    end

    it "persists a partial set when only one capability is active" do
      allow(Stripe::Account).to receive(:retrieve)
        .and_return(stripe_account_with(cashapp_payments: "active", card_payments: "active"))

      expect(service.refresh!).to eq(%w[cashapp])
      expect(merchant_account.reload.us_locked_payment_method_availability["payment_method_types"]).to eq(%w[cashapp])
    end

    it "persists an empty set when the capabilities are absent — a typical non-US connected account" do
      allow(Stripe::Account).to receive(:retrieve)
        .and_return(stripe_account_with(card_payments: "active", transfers: "active"))

      expect(service.refresh!).to eq([])
      expect(merchant_account.reload.us_locked_payment_method_availability["payment_method_types"]).to eq([])
    end

    it "treats an inactive capability as unavailable — only \"active\" counts" do
      allow(Stripe::Account).to receive(:retrieve)
        .and_return(stripe_account_with(cashapp_payments: "pending", us_bank_account_ach_payments: "inactive"))

      expect(service.refresh!).to eq([])
    end

    it "does nothing for a Gumroad-managed account — their charges run on the platform account" do
      managed = create(:merchant_account, user: seller)

      expect(Stripe::Account).not_to receive(:retrieve)
      expect(described_class.new(managed).refresh!).to eq([])
      expect(managed.reload.us_locked_payment_method_availability).to be_nil
    end
  end

  describe "#cached_payment_method_types" do
    it "returns nil when no snapshot has been taken" do
      expect(service.cached_payment_method_types).to be_nil
    end

    it "returns the snapshot's methods, filtered to the known US-locked set" do
      merchant_account.update!(us_locked_payment_method_availability: {
                                 "payment_method_types" => %w[cashapp something_unknown],
                                 "refreshed_at" => Time.current.iso8601,
                               })

      expect(service.cached_payment_method_types).to eq(%w[cashapp])
    end
  end

  describe "#cache_present?" do
    it "distinguishes an empty snapshot (an answer) from a missing one" do
      expect(service.cache_present?).to be(false)

      merchant_account.update!(us_locked_payment_method_availability: {
                                 "payment_method_types" => [],
                                 "refreshed_at" => Time.current.iso8601,
                               })

      expect(service.cache_present?).to be(true)
    end
  end
end
