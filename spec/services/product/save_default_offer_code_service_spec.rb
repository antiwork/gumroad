# frozen_string_literal: true

RSpec.describe Product::SaveDefaultOfferCodeService do
  let(:seller) { create(:user) }
  let(:product) { create(:product, user: seller, price_cents: 1000) }
  let(:offer_code) { create(:offer_code, user: seller, products: [product], amount_cents: 100) }
  let(:service) { described_class.new(product, offer_code_id) }

  describe "#perform" do
    context "when offer_code_id is valid" do
      let(:offer_code_id) { offer_code.external_id }

      it "sets the default offer code on the product" do
        service.perform

        expect(product.default_offer_code).to eq(offer_code)
      end
    end

    context "when offer_code_id is blank" do
      let(:offer_code_id) { nil }

      it "clears the default offer code" do
        product.update!(default_offer_code: offer_code)

        service.perform

        expect(product.default_offer_code).to be_nil
      end
    end

    context "when offer_code_id is empty string" do
      let(:offer_code_id) { "" }

      it "clears the default offer code" do
        product.update!(default_offer_code: offer_code)

        service.perform

        expect(product.default_offer_code).to be_nil
      end
    end

    context "when offer code does not exist" do
      let(:offer_code_id) { "nonexistent_id" }

      it "raises ActiveRecord::RecordNotFound" do
        expect { service.perform }.to raise_error(ActiveRecord::RecordNotFound, "Offer code not found")
      end
    end

    context "when offer code is expired" do
      let(:offer_code_id) { offer_code.external_id }

      before do
        offer_code.update!(valid_at: 2.days.ago, expires_at: 1.day.ago)
      end

      it "raises ActiveRecord::RecordInvalid with appropriate message" do
        expect { service.perform }.to raise_error(ActiveRecord::RecordInvalid) do |error|
          expect(error.record.errors[:default_offer_code]).to include("Offer code is not active")
        end
      end
    end

    context "when offer code valid_at is in the future" do
      let(:offer_code_id) { offer_code.external_id }

      before do
        offer_code.update!(valid_at: 1.day.from_now)
      end

      it "raises ActiveRecord::RecordInvalid with appropriate message" do
        expect { service.perform }.to raise_error(ActiveRecord::RecordInvalid) do |error|
          expect(error.record.errors[:default_offer_code]).to include("Offer code is not active")
        end
      end
    end

    context "when offer code has no remaining uses" do
      let(:offer_code_id) { offer_code.external_id }

      before do
        offer_code.update!(max_purchase_count: 1)
        allow(offer_code).to receive(:times_used).and_return(1)
        allow(product).to receive(:find_offer_code_by_external_id).with(offer_code_id).and_return(offer_code)
      end

      it "raises ActiveRecord::RecordInvalid with appropriate message" do
        expect { service.perform }.to raise_error(ActiveRecord::RecordInvalid) do |error|
          expect(error.record.errors[:default_offer_code]).to include("Offer code has no remaining uses")
        end
      end
    end

    context "with a percentage offer code" do
      let(:percentage_offer_code) { create(:percentage_offer_code, user: seller, products: [product]) }
      let(:offer_code_id) { percentage_offer_code.external_id }

      it "sets the default offer code on the product" do
        service.perform

        expect(product.default_offer_code).to eq(percentage_offer_code)
      end
    end

    context "with a universal offer code" do
      let(:universal_offer_code) { create(:universal_offer_code, user: seller) }
      let(:offer_code_id) { universal_offer_code.external_id }

      it "sets the default offer code on the product" do
        service.perform

        expect(product.default_offer_code).to eq(universal_offer_code)
      end
    end

    context "when changing from one offer code to another" do
      let(:new_offer_code) { create(:offer_code, user: seller, products: [product], code: "newcode", amount_cents: 200) }
      let(:offer_code_id) { new_offer_code.external_id }

      before do
        product.update!(default_offer_code: offer_code)
      end

      it "updates the default offer code" do
        service.perform

        expect(product.default_offer_code).to eq(new_offer_code)
      end
    end
  end
end
