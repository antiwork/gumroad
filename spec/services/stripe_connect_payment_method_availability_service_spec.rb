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
    it "persists the account's full capabilities hash, not just the methods consulted today" do
      allow(Stripe::Account).to receive(:retrieve)
        .with(merchant_account.charge_processor_merchant_id)
        .and_return(stripe_account_with(cashapp_payments: "active", us_bank_account_ach_payments: "active", card_payments: "active", sepa_debit_payments: "active"))

      expect(service.refresh!).to eq(
        "cashapp_payments" => "active",
        "us_bank_account_ach_payments" => "active",
        "card_payments" => "active",
        "sepa_debit_payments" => "active",
      )
      snapshot = merchant_account.reload.stripe_capabilities_snapshot
      expect(snapshot["capabilities"]).to include("card_payments" => "active", "sepa_debit_payments" => "active")
      expect(snapshot["refreshed_at"]).to be_present
    end

    it "persists non-active states verbatim so read-time filtering can distinguish pending from absent" do
      allow(Stripe::Account).to receive(:retrieve)
        .and_return(stripe_account_with(cashapp_payments: "pending", card_payments: "active"))

      service.refresh!

      expect(merchant_account.reload.stripe_capabilities_snapshot["capabilities"]).to eq(
        "cashapp_payments" => "pending", "card_payments" => "active"
      )
    end

    it "persists an empty hash when the account reports no capabilities" do
      allow(Stripe::Account).to receive(:retrieve).and_return(stripe_account_with(nil))

      expect(service.refresh!).to eq({})
      expect(merchant_account.reload.stripe_capabilities_snapshot["capabilities"]).to eq({})
    end

    it "does nothing for a Gumroad-managed account — their charges run on the platform account" do
      managed = create(:merchant_account, user: seller)

      expect(Stripe::Account).not_to receive(:retrieve)
      expect(described_class.new(managed).refresh!).to eq({})
      expect(managed.reload.stripe_capabilities_snapshot).to be_nil
    end
  end

  describe "#available_payment_method_types" do
    it "returns nil when no snapshot has been taken — the caller owns the fail-safe" do
      expect(service.available_payment_method_types(%w[cashapp us_bank_account])).to be_nil
    end

    it "keeps only the methods whose mapped capability is active" do
      merchant_account.update!(stripe_capabilities_snapshot: {
                                 "capabilities" => { "cashapp_payments" => "active", "us_bank_account_ach_payments" => "inactive" },
                                 "refreshed_at" => Time.current.iso8601,
                               })

      expect(service.available_payment_method_types(%w[cashapp us_bank_account])).to eq(%w[cashapp])
    end

    it "treats a pending capability as unavailable — only \"active\" counts" do
      merchant_account.update!(stripe_capabilities_snapshot: {
                                 "capabilities" => { "cashapp_payments" => "pending" },
                                 "refreshed_at" => Time.current.iso8601,
                               })

      expect(service.available_payment_method_types(%w[cashapp])).to eq([])
    end

    it "answers for methods beyond the US-locked pair — future launches read existing snapshots" do
      merchant_account.update!(stripe_capabilities_snapshot: {
                                 "capabilities" => { "sepa_debit_payments" => "active", "ideal_payments" => "active", "klarna_payments" => "inactive" },
                                 "refreshed_at" => Time.current.iso8601,
                               })

      expect(service.available_payment_method_types(%w[sepa_debit ideal klarna])).to eq(%w[sepa_debit ideal])
    end

    it "fails closed on a method type with no capability mapping" do
      merchant_account.update!(stripe_capabilities_snapshot: {
                                 "capabilities" => { "card_payments" => "active" },
                                 "refreshed_at" => Time.current.iso8601,
                               })

      expect(service.available_payment_method_types(%w[some_future_method])).to eq([])
    end
  end

  describe "#cache_present?" do
    it "distinguishes an empty snapshot (an answer) from a missing one" do
      expect(service.cache_present?).to be(false)

      merchant_account.update!(stripe_capabilities_snapshot: {
                                 "capabilities" => {},
                                 "refreshed_at" => Time.current.iso8601,
                               })

      expect(service.cache_present?).to be(true)
    end
  end

  describe "#snapshot_stale?" do
    it "is false when there is no snapshot — a miss is a miss, not staleness" do
      expect(service.snapshot_stale?).to be(false)
    end

    it "is false for a snapshot refreshed within SNAPSHOT_MAX_AGE" do
      merchant_account.update!(stripe_capabilities_snapshot: {
                                 "capabilities" => {},
                                 "refreshed_at" => 1.hour.ago.iso8601,
                               })

      expect(service.snapshot_stale?).to be(false)
    end

    it "is true for a snapshot older than SNAPSHOT_MAX_AGE" do
      merchant_account.update!(stripe_capabilities_snapshot: {
                                 "capabilities" => {},
                                 "refreshed_at" => (described_class::SNAPSHOT_MAX_AGE + 1.hour).ago.iso8601,
                               })

      expect(service.snapshot_stale?).to be(true)
    end

    it "is true when refreshed_at is missing or unparseable — treat unknown age as stale" do
      merchant_account.update!(stripe_capabilities_snapshot: { "capabilities" => {} })
      expect(service.snapshot_stale?).to be(true)

      merchant_account.update!(stripe_capabilities_snapshot: { "capabilities" => {}, "refreshed_at" => "garbage" })
      expect(service.snapshot_stale?).to be(true)
    end
  end
end
