# frozen_string_literal: true

require "spec_helper"

describe User::FeatureStatus, "Stripe rollout gates" do
  let(:routing_gate) { User::FeatureStatus::LEGAL_ENTITY_COUNTRY_ROUTING_FEATURE }
  let(:rail_gate) { User::FeatureStatus::PAYOUT_RAIL_BESIDE_INACTIVE_CONNECT_FEATURE }

  # merchant_migration_enabled? and has_stripe_account_connected? with the routing gate absent and open.
  shapes = {
    "US company with a French Polynesia representative" => { compliance: { is_business: true, country: "French Polynesia", business_country: "United States" }, closed: [false, false], open: [true, true] },
    "US company with a French Polynesia representative and merchant migration off" => { compliance: { is_business: true, country: "French Polynesia", business_country: "United States" }, merchant_migration: false, closed: [false, false], open: [false, false] },
    "US company with a French Polynesia representative and a linked Connect account" => { compliance: { is_business: true, country: "French Polynesia", business_country: "United States" }, linked: true, closed: [true, true], open: [true, true] },
    "US company with a French Polynesia representative and no Connect row" => { compliance: { is_business: true, country: "French Polynesia", business_country: "United States" }, connect: false, closed: [false, false], open: [true, false] },
    "Indian company with a French representative" => { compliance: { is_business: true, country: "France", business_country: "India" }, closed: [true, true], open: [false, false] },
    "French Polynesia individual" => { compliance: { is_business: false, country: "French Polynesia" }, closed: [false, false], open: [false, false] },
    "French individual" => { compliance: { is_business: false, country: "France" }, closed: [true, true], open: [true, true] },
    "US company with a French Polynesia representative and a managed bank rail" => { compliance: { is_business: true, country: "French Polynesia", business_country: "United States" }, managed: true, closed: [false, false], open: [true, true] },
  }.freeze

  def build_seller(shape)
    seller = create(:user, payment_address: "seller-payouts@example.com", check_merchant_account_is_linked: shape.fetch(:linked, false))
    factory = shape[:compliance][:is_business] ? :user_compliance_info_business : :user_compliance_info
    create(factory, user: seller, **shape[:compliance])
    create(:merchant_account_stripe_connect, user: seller) if shape.fetch(:connect, true)
    if shape[:managed]
      create(:merchant_account, user: seller, country: "US")
      create(:ach_account, user: seller)
    end
    Feature.activate_user(:merchant_migration, seller) if shape.fetch(:merchant_migration, true)
    seller.reload
  end

  def residence_rule(seller)
    seller.check_merchant_account_is_linked ||
      (Feature.active?(:merchant_migration, seller) &&
        StripeMerchantAccountManager::COUNTRIES_SUPPORTED_BY_STRIPE_CONNECT.include?(Compliance::Countries.find_by_name(seller.alive_user_compliance_info.country)&.alpha2))
  end

  shapes.each do |name, shape|
    context "with a #{name}" do
      let(:seller) { build_seller(shape) }

      it "keeps the representative-country rule while the routing gate is absent" do
        expect(Flipper.exist?(routing_gate)).to be(false)
        expect([seller.merchant_migration_enabled?, seller.has_stripe_account_connected?]).to eq(shape[:closed])
        expect(seller.merchant_migration_enabled?).to eq(residence_rule(seller))
      end

      it "keeps the representative-country rule while the routing gate is explicitly off" do
        Feature.deactivate_user(routing_gate, seller)

        expect([seller.merchant_migration_enabled?, seller.has_stripe_account_connected?]).to eq(shape[:closed])
      end

      it "routes by the legal entity's country once the routing gate is open for the seller" do
        Feature.activate_user(routing_gate, seller)

        expect([seller.merchant_migration_enabled?, seller.has_stripe_account_connected?]).to eq(shape[:open])
        expect(seller.stripe_connect_routing_country_code).to eq(seller.alive_user_compliance_info.legal_entity_country_code)
      end

      it "ignores the routing gate opened for a different seller" do
        Feature.activate_user(routing_gate, create(:user))

        expect([seller.merchant_migration_enabled?, seller.has_stripe_account_connected?]).to eq(shape[:closed])
      end
    end
  end

  describe "where card sales and payouts go for the US company with a French Polynesia representative" do
    let(:seller) { build_seller(shapes.values.first) }

    it "keeps Gumroad's account and the PayPal rail while the routing gate is closed" do
      expect(seller.merchant_account(StripeChargeProcessor.charge_processor_id)).to be_nil
      expect(StripePayoutProcessor.pays_user_via_stripe_connect?(seller)).to be(false)
      expect(StripePayoutProcessor.destination_merchant_account(seller, [])).to be_nil
      expect(PaypalPayoutProcessor.is_user_payable(seller, 100_00)).to be(true)
    end

    it "moves card sales and Gumroad-held payouts to the stored Connect account once the gate is open" do
      Feature.activate_user(routing_gate, seller)

      expect(seller.merchant_account(StripeChargeProcessor.charge_processor_id)).to eq(seller.stripe_connect_account)
      expect(StripePayoutProcessor.destination_merchant_account(seller, [])).to eq(seller.stripe_connect_account)
      expect(PaypalPayoutProcessor.is_user_payable(seller, 100_00)).to be(false)
    end
  end

  describe "when the flag store cannot be read" do
    let(:inner_adapter) { Flipper::Adapters::Memory.new }
    let(:flipper) { Flipper.new(Flipper::Adapters::RedisFailOpen.new(inner_adapter)) }
    let(:seller) do
      seller = create(:user)
      create(:user_compliance_info_business, user: seller, country: "French Polynesia")
      create(:merchant_account_stripe_connect, user: seller)
      seller
    end

    before do
      allow(Flipper).to receive(:instance).and_return(flipper)
      allow(ErrorNotifier).to receive(:notify)
      flipper[:merchant_migration].enable_actor(seller)
      # Only merchant_migration is read here, so the rollout gates stay unread.
      expect(flipper[:merchant_migration].enabled?(seller)).to be(true)
    end

    [RedisClient::ReadTimeoutError, Redis::TimeoutError].each do |error_class|
      it "keeps the representative-country rule for a gate it has never read (#{error_class})" do
        flipper[routing_gate].enable_actor(seller)
        allow(inner_adapter).to receive(:get).and_raise(error_class)

        expect(seller.merchant_migration_enabled?).to be(false)
        expect(seller.has_stripe_account_connected?).to be(false)
        expect(seller.payout_rail_beside_inactive_connect_enabled?).to be(false)
      end
    end

    it "keeps a gate that was last read as open" do
      flipper[routing_gate].enable_actor(seller)
      flipper[rail_gate].enable_actor(seller)
      expect(seller.merchant_migration_enabled?).to be(true)
      expect(seller.payout_rail_beside_inactive_connect_enabled?).to be(true)
      allow(inner_adapter).to receive(:get).and_raise(RedisClient::ReadTimeoutError)

      expect(seller.merchant_migration_enabled?).to be(true)
      expect(seller.payout_rail_beside_inactive_connect_enabled?).to be(true)
    end

    it "keeps a gate that was last read as closed" do
      expect(seller.merchant_migration_enabled?).to be(false)
      expect(seller.payout_rail_beside_inactive_connect_enabled?).to be(false)
      allow(inner_adapter).to receive(:get).and_raise(RedisClient::ReadTimeoutError)

      expect(seller.merchant_migration_enabled?).to be(false)
      expect(seller.payout_rail_beside_inactive_connect_enabled?).to be(false)
    end
  end
end
