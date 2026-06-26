# frozen_string_literal: true

require "spec_helper"

describe Ai::StoreAgentActionExecutor do
  let(:seller) { create(:user) }
  let(:pundit_user) { SellerContext.new(user: seller, seller:) }
  let(:executor) { described_class.new(seller:, pundit_user:) }

  describe "#execute" do
    context "create_discount" do
      it "creates a universal percentage discount" do
        result = executor.execute(type: "create_discount", params: { code: "LAUNCH", percent_off: 20 })

        expect(result[:success]).to be(true)
        offer_code = seller.offer_codes.alive.last
        expect(offer_code.code).to eq("LAUNCH")
        expect(offer_code.amount_percentage).to eq(20)
        expect(offer_code.universal?).to be(true)
        # A universal percentage code must stay currency-agnostic so it applies across all products.
        expect(offer_code.currency_type).to be_nil
      end

      it "creates a universal fixed-amount discount" do
        result = executor.execute(type: "create_discount", params: { code: "FIVEOFF", amount_off_cents: 500 })

        expect(result[:success]).to be(true)
        expect(seller.offer_codes.alive.last.amount_cents).to eq(500)
      end

      it "rejects an out-of-range percentage" do
        result = executor.execute(type: "create_discount", params: { code: "NOPE", percent_off: 150 })

        expect(result[:success]).to be(false)
        expect(seller.offer_codes.alive.count).to eq(0)
      end

      it "requires a code" do
        result = executor.execute(type: "create_discount", params: { percent_off: 10 })

        expect(result[:success]).to be(false)
      end
    end

    context "update_product_price" do
      let!(:product) { create(:product, user: seller, price_cents: 1000) }

      it "updates the price" do
        result = executor.execute(type: "update_product_price", params: { product_id: product.external_id, new_price_cents: 2500 })

        expect(result[:success]).to be(true)
        expect(product.reload.price_cents).to eq(2500)
      end

      it "rejects a negative price" do
        result = executor.execute(type: "update_product_price", params: { product_id: product.external_id, new_price_cents: -1 })

        expect(result[:success]).to be(false)
        expect(product.reload.price_cents).to eq(1000)
      end

      it "does not touch another seller's product" do
        other_product = create(:product, price_cents: 1000)

        result = executor.execute(type: "update_product_price", params: { product_id: other_product.external_id, new_price_cents: 5 })

        expect(result[:success]).to be(false)
        expect(other_product.reload.price_cents).to eq(1000)
      end

      it "refuses a tiered membership (price lives on tiers, not price_cents)" do
        membership = create(:membership_product, user: seller)

        result = executor.execute(type: "update_product_price", params: { product_id: membership.external_id, new_price_cents: 5000 })

        expect(result[:success]).to be(false)
        expect(result[:message]).to match(/tier/i)
      end
    end

    context "publish_product / unpublish_product" do
      let!(:product) { create(:product, user: seller, purchase_disabled_at: Time.current) }

      it "publishes a product" do
        result = executor.execute(type: "publish_product", params: { product_id: product.external_id })

        expect(result[:success]).to be(true)
        expect(product.reload.alive?).to be(true)
      end

      it "unpublishes a product" do
        product.publish!
        result = executor.execute(type: "unpublish_product", params: { product_id: product.external_id })

        expect(result[:success]).to be(true)
        expect(product.reload.alive?).to be(false)
      end
    end

    context "unsupported type" do
      it "returns a failure without raising" do
        result = executor.execute(type: "delete_account", params: {})

        expect(result[:success]).to be(false)
        expect(result[:message]).to be_present
      end
    end
  end
end
