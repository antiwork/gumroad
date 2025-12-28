# frozen_string_literal: true

RSpec.describe Link, "default offer code" do
  let(:user) { create(:user) }
  let(:product) { create(:product, user:) }

  describe "#effective_default_offer_code" do
    context "when no default offer code is set" do
      it "returns nil" do
        expect(product.effective_default_offer_code).to be_nil
      end
    end

    context "when a valid default offer code is set" do
      let(:offer_code) { create(:percentage_offer_code, user:, products: [product], amount_percentage: 20) }

      before do
        product.update!(default_offer_code: offer_code)
      end

      it "returns the offer code" do
        expect(product.effective_default_offer_code).to eq(offer_code)
      end
    end

    context "when the default offer code is deleted" do
      let(:offer_code) { create(:percentage_offer_code, user:, products: [product], amount_percentage: 20) }

      before do
        product.update!(default_offer_code: offer_code)
        offer_code.mark_deleted!
      end

      it "returns nil" do
        expect(product.effective_default_offer_code).to be_nil
      end
    end

    context "when the default offer code is expired" do
      let(:offer_code) do
        create(:percentage_offer_code, user:, products: [product], amount_percentage: 20,
                                       valid_at: 2.days.ago, expires_at: 1.day.ago)
      end

      before do
        product.update!(default_offer_code: offer_code)
      end

      it "returns nil" do
        expect(product.effective_default_offer_code).to be_nil
      end
    end

    context "when the default offer code is not yet active" do
      let(:offer_code) do
        create(:percentage_offer_code, user:, products: [product], amount_percentage: 20,
                                       valid_at: 1.day.from_now, expires_at: 2.days.from_now)
      end

      before do
        product.update!(default_offer_code: offer_code)
      end

      it "returns nil" do
        expect(product.effective_default_offer_code).to be_nil
      end
    end
  end

  describe "validation" do
    context "when default offer code is invalid" do
      it "adds an error when the offer code does not exist" do
        product.default_offer_code_id = 999_999_999
        expect(product).not_to be_valid
        expect(product.errors[:default_offer_code]).to include("is invalid or not applicable to this product")
      end

      it "adds an error when the offer code is not applicable to the product" do
        other_product = create(:product, user:)
        other_offer_code = create(:percentage_offer_code, user:, products: [other_product])

        product.default_offer_code = other_offer_code
        expect(product).not_to be_valid
        expect(product.errors[:default_offer_code]).to include("is invalid or not applicable to this product")
      end
    end

    context "when default offer code is valid" do
      let(:offer_code) { create(:percentage_offer_code, user:, products: [product], amount_percentage: 20) }

      it "is valid" do
        product.default_offer_code = offer_code
        expect(product).to be_valid
      end
    end
  end
end

RSpec.describe OfferCode, "clear_as_default_if_deleted" do
  let(:user) { create(:user) }
  let(:product) { create(:product, user:) }
  let(:offer_code) { create(:percentage_offer_code, user:, products: [product], amount_percentage: 20) }

  before do
    product.update!(default_offer_code: offer_code)
  end

  it "clears default_offer_code_id when offer code is deleted" do
    expect(product.default_offer_code_id).to eq(offer_code.id)

    offer_code.mark_deleted!

    product.reload
    expect(product.default_offer_code_id).to be_nil
  end
end
