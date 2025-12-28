# frozen_string_literal: true

RSpec.describe Product::SaveDefaultOfferCodeService do
  let(:user) { create(:user) }
  let(:product) { create(:product, user:) }
  let(:offer_code) { create(:percentage_offer_code, user:, products: [product], amount_percentage: 20) }
  let(:service) { described_class.new(product, offer_code_id) }

  describe "#perform" do
    context "when a valid offer code id is provided" do
      let(:offer_code_id) { offer_code.external_id }

      it "sets the default_offer_code_id on the product" do
        service.perform

        product.reload
        expect(product.default_offer_code_id).to eq(offer_code.id)
        expect(product.default_offer_code).to eq(offer_code)
      end
    end

    context "when a nil offer code id is provided" do
      let(:offer_code_id) { nil }

      before do
        product.update!(default_offer_code: offer_code)
      end

      it "clears the default_offer_code_id on the product" do
        service.perform

        product.reload
        expect(product.default_offer_code_id).to be_nil
        expect(product.default_offer_code).to be_nil
      end
    end

    context "when an empty string offer code id is provided" do
      let(:offer_code_id) { "" }

      before do
        product.update!(default_offer_code: offer_code)
      end

      it "clears the default_offer_code_id on the product" do
        service.perform

        product.reload
        expect(product.default_offer_code_id).to be_nil
      end
    end

    context "when offer code does not exist" do
      let(:offer_code_id) { "nonexistent_id" }

      it "raises ActiveRecord::RecordNotFound" do
        expect { service.perform }.to raise_error(ActiveRecord::RecordNotFound)
      end
    end

    context "when offer code is deleted" do
      let(:offer_code_id) { offer_code.external_id }

      before do
        offer_code.mark_deleted!
      end

      it "raises ActiveRecord::RecordNotFound" do
        expect { service.perform }.to raise_error(ActiveRecord::RecordNotFound)
      end
    end

    context "when offer code is not applicable to the product" do
      let(:other_product) { create(:product, user:) }
      let(:other_offer_code) { create(:percentage_offer_code, user:, products: [other_product]) }
      let(:offer_code_id) { other_offer_code.external_id }

      it "raises ArgumentError" do
        expect { service.perform }.to raise_error(ActiveRecord::RecordNotFound)
      end
    end

    context "with a universal offer code" do
      let(:universal_offer_code) { create(:percentage_offer_code, user:, universal: true, amount_percentage: 15) }
      let(:offer_code_id) { universal_offer_code.external_id }

      it "sets the default_offer_code_id on the product" do
        service.perform

        product.reload
        expect(product.default_offer_code_id).to eq(universal_offer_code.id)
        expect(product.default_offer_code).to eq(universal_offer_code)
      end
    end
  end
end
