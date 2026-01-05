# frozen_string_literal: true

require "spec_helper"

describe Link, "default offer code" do
  let(:user) { create(:user) }
  let(:product) { create(:product, user: user, price_cents: 10_00) }
  let(:offer_code) { create(:offer_code, user: user, products: [product], amount_cents: 2_00) }

  describe "validations" do
    context "when default_offer_code belongs to a different seller" do
      let(:other_user) { create(:user) }
      let(:other_product) { create(:product, user: other_user) }
      let(:other_offer_code) { create(:offer_code, user: other_user, products: [other_product]) }

      it "is invalid" do
        product.default_offer_code = other_offer_code
        expect(product).not_to be_valid
        expect(product.errors[:default_offer_code]).to include("must belong to the same seller")
      end
    end

    context "when default_offer_code does not apply to this product" do
      let(:other_product) { create(:product, user: user) }
      let(:other_offer_code) { create(:offer_code, user: user, products: [other_product]) }

      it "is invalid" do
        product.default_offer_code = other_offer_code
        expect(product).not_to be_valid
        expect(product.errors[:default_offer_code]).to include("must be applicable to this product")
      end
    end

    context "when default_offer_code is inactive" do
      before { offer_code.update!(expires_at: 1.day.ago, valid_at: 2.days.ago) }

      it "is invalid" do
        product.default_offer_code = offer_code
        expect(product).not_to be_valid
        expect(product.errors[:default_offer_code]).to include("must be an active discount code")
      end
    end

    context "when default_offer_code is valid" do
      it "is valid" do
        product.default_offer_code = offer_code
        expect(product).to be_valid
      end
    end
  end

  describe "#effective_default_offer_code" do
    context "when default_offer_code_enabled is false" do
      before do
        product.update!(default_offer_code: offer_code, default_offer_code_enabled: false)
      end

      it "returns nil" do
        expect(product.effective_default_offer_code).to be_nil
      end
    end

    context "when default_offer_code is nil" do
      before do
        product.update!(default_offer_code: nil, default_offer_code_enabled: true)
      end

      it "returns nil" do
        expect(product.effective_default_offer_code).to be_nil
      end
    end

    context "when default_offer_code is inactive" do
      before do
        product.update!(default_offer_code: offer_code, default_offer_code_enabled: true)
        offer_code.update_column(:expires_at, 1.day.ago)
      end

      it "returns nil" do
        expect(product.effective_default_offer_code).to be_nil
      end
    end

    context "when default_offer_code has exceeded max uses" do
      before do
        offer_code.update!(max_purchase_count: 1)
        create(:purchase, link: product, offer_code: offer_code)
        product.update!(default_offer_code: offer_code, default_offer_code_enabled: true)
      end

      it "returns nil" do
        expect(product.effective_default_offer_code).to be_nil
      end
    end

    context "when default_offer_code is valid and enabled" do
      before do
        product.update!(default_offer_code: offer_code, default_offer_code_enabled: true)
      end

      it "returns the offer code" do
        expect(product.effective_default_offer_code).to eq(offer_code)
      end
    end
  end

  describe "#default_discounted_price_cents" do
    context "when there is no effective default offer code" do
      it "returns nil" do
        expect(product.default_discounted_price_cents).to be_nil
      end
    end

    context "when there is an effective default offer code" do
      before do
        product.update!(default_offer_code: offer_code, default_offer_code_enabled: true)
      end

      it "returns the discounted price" do
        # Product is $10, discount is $2
        expect(product.default_discounted_price_cents).to eq(8_00)
      end
    end

    context "with a percentage discount" do
      let(:percentage_offer_code) { create(:percentage_offer_code, user: user, products: [product], amount_percentage: 20) }

      before do
        product.update!(default_offer_code: percentage_offer_code, default_offer_code_enabled: true)
      end

      it "returns the discounted price" do
        # Product is $10, discount is 20%
        expect(product.default_discounted_price_cents).to eq(8_00)
      end
    end
  end
end
