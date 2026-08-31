# frozen_string_literal: true

require "spec_helper"

describe AlertOnZeroBuyerCurrencyWalletPurchasesJob do
  before do
    allow(InternalNotificationWorker).to receive(:perform_async)
    Feature.deactivate(Checkout::BuyerCurrencyEligibility::WALLETS_FEATURE_NAME)
    Feature.deactivate_percentage(Checkout::BuyerCurrencyEligibility::WALLETS_FEATURE_NAME)
    Feature.deactivate(Checkout::BuyerCurrencyEligibility::PAYMENT_ELEMENT_WALLETS_FEATURE_NAME)
    Feature.deactivate_percentage(Checkout::BuyerCurrencyEligibility::PAYMENT_ELEMENT_WALLETS_FEATURE_NAME)
    $redis.del(RedisKey.buyer_currency_wallet_presentment_zero_alerted_at)
  end

  def enable_wallet_lane
    Feature.activate(Checkout::BuyerCurrencyEligibility::WALLETS_FEATURE_NAME)
    Feature.activate(Checkout::BuyerCurrencyEligibility::PAYMENT_ELEMENT_WALLETS_FEATURE_NAME)
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
    it "stays quiet and clears the alert throttle while the wallet flag is off" do
      $redis.set(RedisKey.buyer_currency_wallet_presentment_zero_alerted_at, 1.hour.ago.to_i)

      described_class.new.perform

      expect(InternalNotificationWorker).not_to have_received(:perform_async)
      expect($redis.get(RedisKey.buyer_currency_wallet_presentment_zero_alerted_at)).to be_nil
    end

    it "stays quiet when payment_element_wallets is off even if buyer_currency_wallets is on" do
      Feature.activate(Checkout::BuyerCurrencyEligibility::WALLETS_FEATURE_NAME)
      $redis.set(RedisKey.buyer_currency_wallet_presentment_zero_alerted_at, 1.hour.ago.to_i)

      described_class.new.perform

      expect(InternalNotificationWorker).not_to have_received(:perform_async)
      expect($redis.get(RedisKey.buyer_currency_wallet_presentment_zero_alerted_at)).to be_nil
    end

    it "alerts as soon as the already-full 24-hour purchase window is empty" do
      enable_wallet_lane

      described_class.new.perform

      expect(InternalNotificationWorker).to have_received(:perform_async) do |room, sender, message|
        expect(room).to eq("agent_reports")
        expect(sender).to eq("Buyer-currency wallet purchases at zero")
        expect(message).to include("has ever been recorded")
        expect(message).to include("370–420")
      end
      expect($redis.get(RedisKey.buyer_currency_wallet_presentment_zero_alerted_at)).to be_present
    end

    it "reports the newest wallet-presentment purchase when the drought is older than the threshold" do
      enable_wallet_lane
      last_purchase_at = 25.hours.ago
      create_wallet_presentment_purchase(created_at: 3.days.ago)
      create_wallet_presentment_purchase(created_at: last_purchase_at)

      described_class.new.perform

      expect(InternalNotificationWorker).to have_received(:perform_async) do |_room, _sender, message|
        expect(message).to include(last_purchase_at.utc.strftime("%Y-%m-%d %H:%M UTC"))
        expect(message).to include("25 hours")
      end
    end

    it "treats a percentage rollout as enabled when a historical seller is in both flags" do
      create_wallet_presentment_purchase(created_at: 25.hours.ago)
      Feature.activate(Checkout::BuyerCurrencyEligibility::PAYMENT_ELEMENT_WALLETS_FEATURE_NAME)
      Feature.activate_percentage(Checkout::BuyerCurrencyEligibility::WALLETS_FEATURE_NAME, 100)

      described_class.new.perform

      expect(InternalNotificationWorker).to have_received(:perform_async)
    end

    it "alerts on actor rollouts only when the same historical seller is in both flags" do
      purchase = create_wallet_presentment_purchase(created_at: 25.hours.ago)
      Feature.activate_user(Checkout::BuyerCurrencyEligibility::PAYMENT_ELEMENT_WALLETS_FEATURE_NAME, purchase.seller)
      Feature.activate_user(Checkout::BuyerCurrencyEligibility::WALLETS_FEATURE_NAME, purchase.seller)

      described_class.new.perform

      expect(InternalNotificationWorker).to have_received(:perform_async)
    end

    it "stays quiet when the two actor rollouts do not overlap on a historical seller" do
      payment_element_purchase = create_wallet_presentment_purchase(created_at: 25.hours.ago)
      buyer_currency_purchase = create_wallet_presentment_purchase(created_at: 25.hours.ago)
      Feature.activate_user(Checkout::BuyerCurrencyEligibility::PAYMENT_ELEMENT_WALLETS_FEATURE_NAME, payment_element_purchase.seller)
      Feature.activate_user(Checkout::BuyerCurrencyEligibility::WALLETS_FEATURE_NAME, buyer_currency_purchase.seller)

      described_class.new.perform

      expect(InternalNotificationWorker).not_to have_received(:perform_async)
    end

    it "throttles repeated alerts while the lane remains at zero" do
      enable_wallet_lane
      $redis.set(RedisKey.buyer_currency_wallet_presentment_zero_alerted_at, 1.hour.ago.to_i)

      described_class.new.perform

      expect(InternalNotificationWorker).not_to have_received(:perform_async)
    end

    it "does not enqueue when a concurrent run already claimed the throttle" do
      enable_wallet_lane
      allow($redis).to receive(:set).and_call_original
      allow($redis).to receive(:set).with(
        RedisKey.buyer_currency_wallet_presentment_zero_alerted_at,
        anything,
        hash_including(nx: true)
      ).and_return(false)

      described_class.new.perform

      expect(InternalNotificationWorker).not_to have_received(:perform_async)
    end

    it "releases the throttle when enqueue fails so Sidekiq retries can alert" do
      enable_wallet_lane
      allow(InternalNotificationWorker).to receive(:perform_async).and_raise(Redis::BaseError)

      expect { described_class.new.perform }.to raise_error(Redis::BaseError)

      expect($redis.get(RedisKey.buyer_currency_wallet_presentment_zero_alerted_at)).to be_nil
    end

    it "stays quiet and clears the alert throttle when a recent wallet purchase has a presentment row" do
      enable_wallet_lane
      $redis.set(RedisKey.buyer_currency_wallet_presentment_zero_alerted_at, 2.days.ago.to_i)
      create_wallet_presentment_purchase(created_at: 2.hours.ago)

      described_class.new.perform

      expect(InternalNotificationWorker).not_to have_received(:perform_async)
      expect($redis.get(RedisKey.buyer_currency_wallet_presentment_zero_alerted_at)).to be_nil
    end

    it "ignores wallet purchases without a presentment row" do
      enable_wallet_lane
      purchase = create(:purchase, purchase_state: "successful", created_at: 2.hours.ago)
      PurchaseWalletType.create!(purchase:, wallet_type: "apple_pay")

      described_class.new.perform

      expect(InternalNotificationWorker).to have_received(:perform_async)
    end

    it "ignores presentment purchases that did not use a wallet" do
      enable_wallet_lane
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
