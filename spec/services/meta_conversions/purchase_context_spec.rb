# frozen_string_literal: true

require "spec_helper"

describe MetaConversions::PurchaseContext do
  let(:seller) { create(:user, facebook_pixel_id: "1056510450054835") }
  let(:product) { create(:product, user: seller, price_cents: 20_00) }
  let(:purchase) { create(:purchase, link: product, seller:) }
  let(:key) { RedisKey.meta_conversions_purchase_context(purchase.id) }

  before do
    MerchantAccount.find_or_create_by!(user_id: nil, charge_processor_id: StripeChargeProcessor.charge_processor_id) do |merchant_account|
      merchant_account.charge_processor_alive_at = Time.current
    end
    Feature.activate_user(:meta_conversions_api, seller)
    seller.create_meta_conversions_setting!(access_token: "seller-token")
  end

  describe ".save_for" do
    it "saves the user agent and the host for an eligible seller" do
      described_class.save_for([purchase], user_agent: "Mozilla/5.0", base_url: "https://shop.example.com")

      expect(JSON.parse($redis.get(key))).to eq("user_agent" => "Mozilla/5.0", "base_url" => "https://shop.example.com")
    end

    it "keeps the saved context for seven days" do
      described_class.save_for([purchase], user_agent: "Mozilla/5.0", base_url: "https://shop.example.com")

      expect($redis.ttl(key)).to be_within(60).of(7.days.to_i)
    end

    it "saves nothing for a seller that fails a seller gate" do
      Feature.deactivate_user(:meta_conversions_api, seller)

      described_class.save_for([purchase.reload], user_agent: "Mozilla/5.0", base_url: "https://shop.example.com")

      expect($redis.get(key)).to be_nil
    end
  end

  describe ".fetch" do
    it "reads back the saved context" do
      described_class.save_for([purchase], user_agent: "Mozilla/5.0", base_url: "https://shop.example.com")

      expect(described_class.fetch(purchase.id)).to eq(user_agent: "Mozilla/5.0", base_url: "https://shop.example.com")
    end

    it "returns nil when nothing was saved" do
      expect(described_class.fetch(purchase.id)).to be_nil
    end
  end
end
