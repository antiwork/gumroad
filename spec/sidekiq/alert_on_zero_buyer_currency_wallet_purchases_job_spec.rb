# frozen_string_literal: true

require "spec_helper"

describe AlertOnZeroBuyerCurrencyWalletPurchasesJob do
  before do
    allow(InternalNotificationWorker).to receive(:perform_async)
    Feature.deactivate(Checkout::BuyerCurrencyEligibility::WALLETS_FEATURE_NAME)
    Feature.deactivate_percentage(Checkout::BuyerCurrencyEligibility::WALLETS_FEATURE_NAME)
    $redis.del(RedisKey.buyer_currency_wallet_presentment_zero_first_seen_at)
    $redis.del(RedisKey.buyer_currency_wallet_presentment_zero_alerted_at)
  end

  def create_presentment_for(purchase)
    PurchasePresentment.create!(
      purchase:,
      processor: StripeChargeProcessor.charge_processor_id,
      presentment_currency: Currency::CAD,
      presentment_price_cents: 12_00,
      presentment_tip_cents: 0,
      presentment_seller_tax_cents: 0,
      presentment_gumroad_tax_cents: 1_50,
      presentment_shipping_cents: 0,
      presentment_total_cents: 13_50,
      presentment_gumroad_amount_cents: 1_35,
    )
  end

  def create_wallet_presentment_purchase(created_at: Time.current, wallet_type: "apple_pay")
    purchase = create(:purchase, purchase_state: "successful", created_at:)
    create_presentment_for(purchase)
    PurchaseWalletType.create!(purchase:, wallet_type:)
    purchase
  end

  describe "#perform" do
    it "stays quiet and clears the zero window while the wallet flag is off" do
      $redis.set(RedisKey.buyer_currency_wallet_presentment_zero_first_seen_at, 2.days.ago.to_i)

      described_class.new.perform

      expect(InternalNotificationWorker).not_to have_received(:perform_async)
      expect($redis.get(RedisKey.buyer_currency_wallet_presentment_zero_first_seen_at)).to be_nil
    end

    it "records the first zero-volume observation without alerting" do
      Feature.activate(Checkout::BuyerCurrencyEligibility::WALLETS_FEATURE_NAME)

      described_class.new.perform

      expect(InternalNotificationWorker).not_to have_received(:perform_async)
      expect($redis.get(RedisKey.buyer_currency_wallet_presentment_zero_first_seen_at)).to be_present
    end

    it "alerts when zero volume has lasted for a full day while the flag is enabled" do
      Feature.activate(Checkout::BuyerCurrencyEligibility::WALLETS_FEATURE_NAME)
      first_seen_at = described_class::ZERO_VOLUME_WINDOW.ago - 1.hour
      $redis.set(RedisKey.buyer_currency_wallet_presentment_zero_first_seen_at, first_seen_at.to_i)

      described_class.new.perform

      expect(InternalNotificationWorker).to have_received(:perform_async) do |room, sender, message|
        expect(room).to eq("agent_reports")
        expect(sender).to eq("Buyer-currency wallet purchases at zero")
        expect(message).to include("buyer_currency_wallets is enabled")
        expect(message).to include("370–420")
      end
    end

    it "treats a percentage rollout as enabled" do
      Feature.activate_percentage(Checkout::BuyerCurrencyEligibility::WALLETS_FEATURE_NAME, 100)
      $redis.set(RedisKey.buyer_currency_wallet_presentment_zero_first_seen_at, 2.days.ago.to_i)

      described_class.new.perform

      expect(InternalNotificationWorker).to have_received(:perform_async)
    end

    it "throttles repeated alerts while the lane remains at zero" do
      Feature.activate(Checkout::BuyerCurrencyEligibility::WALLETS_FEATURE_NAME)
      $redis.set(RedisKey.buyer_currency_wallet_presentment_zero_first_seen_at, 2.days.ago.to_i)
      $redis.set(RedisKey.buyer_currency_wallet_presentment_zero_alerted_at, 1.hour.ago.to_i)

      described_class.new.perform

      expect(InternalNotificationWorker).not_to have_received(:perform_async)
    end

    it "stays quiet and clears the zero window when a recent wallet purchase has a presentment row" do
      Feature.activate(Checkout::BuyerCurrencyEligibility::WALLETS_FEATURE_NAME)
      $redis.set(RedisKey.buyer_currency_wallet_presentment_zero_first_seen_at, 2.days.ago.to_i)
      $redis.set(RedisKey.buyer_currency_wallet_presentment_zero_alerted_at, 2.days.ago.to_i)
      create_wallet_presentment_purchase(created_at: 2.hours.ago)

      described_class.new.perform

      expect(InternalNotificationWorker).not_to have_received(:perform_async)
      expect($redis.get(RedisKey.buyer_currency_wallet_presentment_zero_first_seen_at)).to be_nil
      expect($redis.get(RedisKey.buyer_currency_wallet_presentment_zero_alerted_at)).to be_nil
    end

    it "ignores wallet purchases without a presentment row" do
      Feature.activate(Checkout::BuyerCurrencyEligibility::WALLETS_FEATURE_NAME)
      $redis.set(RedisKey.buyer_currency_wallet_presentment_zero_first_seen_at, 2.days.ago.to_i)
      purchase = create(:purchase, purchase_state: "successful", created_at: 2.hours.ago)
      PurchaseWalletType.create!(purchase:, wallet_type: "apple_pay")

      described_class.new.perform

      expect(InternalNotificationWorker).to have_received(:perform_async)
    end

    it "ignores presentment purchases that did not use a wallet" do
      Feature.activate(Checkout::BuyerCurrencyEligibility::WALLETS_FEATURE_NAME)
      $redis.set(RedisKey.buyer_currency_wallet_presentment_zero_first_seen_at, 2.days.ago.to_i)
      purchase = create(:purchase, purchase_state: "successful", created_at: 2.hours.ago)
      create_presentment_for(purchase)

      described_class.new.perform

      expect(InternalNotificationWorker).to have_received(:perform_async)
    end
  end

  describe "schedule" do
    let(:schedule) { YAML.load_file(Rails.root.join("config", "sidekiq_schedule.yml")) }

    it "is registered on the schedule so it actually runs" do
      expect(schedule.values.map { |entry| entry["class"] }).to include(described_class.name)
    end
  end

  # Every example above stubs the worker, so nothing else would notice the room going away —
  # and InternalNotificationMailer#notify returns silently when the room has no recipient, which
  # would leave this job permanently dark with all specs green.
  it "sends to a room that resolves to a real recipient" do
    mail = InternalNotificationMailer.notify(room_name: described_class::ALERT_ROOM, sender: "spec", message_text: "hello")

    expect(mail.to).to be_present
  end
end
