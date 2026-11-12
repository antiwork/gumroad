# frozen_string_literal: true

require "spec_helper"

describe MetaConversions::Eligibility do
  let(:seller) { create(:user, facebook_pixel_id: "1056510450054835") }
  let(:product) { create(:product, user: seller, price_cents: 20_00) }
  let(:purchase) do
    create(:purchase, link: product, seller:, ip_country: "United States", country: "United States", succeeded_at: 1.hour.ago)
  end
  let(:context) { { user_agent: "Mozilla/5.0", base_url: "https://shop.example.com" } }

  before do
    MerchantAccount.find_or_create_by!(user_id: nil, charge_processor_id: StripeChargeProcessor.charge_processor_id) do |merchant_account|
      merchant_account.charge_processor_alive_at = Time.current
    end
    Feature.activate_user(:meta_conversions_api, seller)
    seller.create_meta_conversions_setting!(access_token: "seller-token")
  end

  describe ".seller_skip_reason" do
    it "returns nil when every seller gate passes" do
      expect(described_class.seller_skip_reason(seller)).to be_nil
    end

    it "skips when the flag is off for the seller" do
      Feature.deactivate_user(:meta_conversions_api, seller)

      expect(described_class.seller_skip_reason(seller)).to eq(:flag_off)
    end

    it "skips when the seller has no pixel id" do
      seller.update!(facebook_pixel_id: nil)

      expect(described_class.seller_skip_reason(seller)).to eq(:no_pixel_id)
    end

    it "skips when no token is saved" do
      seller.meta_conversions_setting.destroy!

      expect(described_class.seller_skip_reason(seller.reload)).to eq(:no_token)
    end

    it "skips after Meta rejected the saved token" do
      seller.meta_conversions_setting.update!(token_rejected_at: Time.current)

      expect(described_class.seller_skip_reason(seller)).to eq(:token_rejected)
    end

    it "skips when the seller turned third-party analytics off" do
      seller.update!(disable_third_party_analytics: true)

      expect(described_class.seller_skip_reason(seller)).to eq(:third_party_analytics_disabled)
    end
  end

  describe ".purchase_skip_reason" do
    it "returns nil when every purchase gate passes" do
      expect(described_class.purchase_skip_reason(purchase, context)).to be_nil
    end

    it "skips a purchase with no saved context" do
      expect(described_class.purchase_skip_reason(purchase, nil)).to eq(:no_context)
    end

    it "skips a free sale when the seller turned free sale analytics off" do
      seller.update!(skip_free_sale_analytics: true)
      free_purchase = create(:purchase, link: create(:product, user: seller, price_cents: 0), seller:, ip_country: "United States")

      expect(described_class.purchase_skip_reason(free_purchase, context)).to eq(:free_sale_analytics_disabled)
    end

    it "sends a free sale when the seller left free sale analytics on" do
      free_purchase = create(:purchase, link: create(:product, user: seller, price_cents: 0), seller:, ip_country: "United States")

      expect(described_class.purchase_skip_reason(free_purchase, context)).to be_nil
    end

    it "skips a test purchase" do
      allow(purchase).to receive(:is_test_purchase?).and_return(true)

      expect(described_class.purchase_skip_reason(purchase, context)).to eq(:test_purchase)
    end

    it "skips a recurring subscription charge" do
      allow(purchase).to receive(:is_recurring_subscription_charge).and_return(true)

      expect(described_class.purchase_skip_reason(purchase, context)).to eq(:recurring_subscription_charge)
    end

    it "skips a bundle product purchase" do
      allow(purchase).to receive(:is_bundle_product_purchase).and_return(true)

      expect(described_class.purchase_skip_reason(purchase, context)).to eq(:bundle_product_purchase)
    end

    it "skips a gift receiver purchase" do
      allow(purchase).to receive(:is_gift_receiver_purchase).and_return(true)

      expect(described_class.purchase_skip_reason(purchase, context)).to eq(:gift_receiver_purchase)
    end

    it "skips a purchase with no IP country" do
      purchase.update!(ip_country: nil)

      expect(described_class.purchase_skip_reason(purchase, context)).to eq(:no_ip_country)
    end

    it "skips a buyer in a restricted IP country" do
      purchase.update!(ip_country: "Germany")

      expect(described_class.purchase_skip_reason(purchase, context)).to eq(:restricted_country)
    end

    it "skips a buyer in a restricted billing country" do
      restricted = create(:purchase, link: product, seller:, ip_country: "United States", country: "Switzerland", succeeded_at: 1.hour.ago)

      expect(described_class.purchase_skip_reason(restricted, context)).to eq(:restricted_country)
    end

    it "skips a buyer in Norway" do
      norwegian = create(:purchase, link: product, seller:, ip_country: "Norway", succeeded_at: 1.hour.ago)

      expect(described_class.purchase_skip_reason(norwegian, context)).to eq(:restricted_country)
    end

    it "skips a buyer in the United Kingdom" do
      purchase.update!(country: "United Kingdom")

      expect(described_class.purchase_skip_reason(purchase, context)).to eq(:restricted_country)
    end

    it "sends a purchase from outside the restricted countries" do
      purchase.update!(ip_country: "Canada", country: "Canada")

      expect(described_class.purchase_skip_reason(purchase, context)).to be_nil
    end

    it "skips a purchase that succeeded more than seven days ago" do
      purchase.update!(succeeded_at: 8.days.ago)

      expect(described_class.purchase_skip_reason(purchase, context)).to eq(:outside_send_window)
    end
  end
end
