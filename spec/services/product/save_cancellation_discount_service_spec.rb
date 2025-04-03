# frozen_string_literal: true

RSpec.describe Product::SaveCancellationDiscountService do
  let(:product) { create(:membership_product_with_preset_tiered_pricing) }
  let(:service) { described_class.new(product, cancellation_discount_params) }

  describe "#perform" do
    context "with fixed amount discount" do
      let(:cancellation_discount_params) do
        {
          discount: {
            type: "fixed",
            cents: 100
          },
          duration_in_billing_cycles: 3
        }
      end

      it "creates a new fixed amount cancellation discount offer code" do
        service.perform

        offer_code = product.cancellation_discount_offer_code
        expect(offer_code).to be_present
        expect(offer_code.amount_cents).to eq(100)
        expect(offer_code.amount_percentage).to be_nil
        expect(offer_code.duration_in_billing_cycles).to eq(3)
        expect(offer_code.code).to be_nil
        expect(offer_code.products).to eq([product])
        expect(offer_code.is_cancellation_discount).to eq(true)
      end

      context "when duration_in_billing_cycles is nil" do
        let(:cancellation_discount_params) do
          {
            discount: {
              type: "fixed",
              cents: 100
            },
            duration_in_billing_cycles: nil
          }
        end

        it "creates offer code with nil duration" do
          service.perform

          offer_code = product.cancellation_discount_offer_code
          expect(offer_code).to be_present
          expect(offer_code.duration_in_billing_cycles).to be_nil
        end
      end

      context "when cancellation discount already exists" do
        let!(:existing_offer_code) { create(:fixed_cancellation_discount_offer_code, user: product.user, products: [product]) }

        it "updates the existing offer code" do
          service.perform

          existing_offer_code.reload
          expect(existing_offer_code.amount_cents).to eq(100)
          expect(existing_offer_code.amount_percentage).to be_nil
          expect(existing_offer_code.duration_in_billing_cycles).to eq(3)
        end
      end
    end

    context "with percentage discount" do
      let(:cancellation_discount_params) do
        {
          discount: {
            type: "percentage",
            percents: 20
          },
          duration_in_billing_cycles: 2
        }
      end

      it "creates a new percentage cancellation discount offer code" do
        service.perform

        offer_code = product.cancellation_discount_offer_code
        expect(offer_code).to be_present
        expect(offer_code.amount_percentage).to eq(20)
        expect(offer_code.amount_cents).to be_nil
        expect(offer_code.duration_in_billing_cycles).to eq(2)
        expect(offer_code).to be_is_cancellation_discount
      end

      context "when duration_in_billing_cycles is nil" do
        let(:cancellation_discount_params) do
          {
            discount: {
              type: "percentage",
              percents: 20
            },
            duration_in_billing_cycles: nil
          }
        end

        it "creates offer code with nil duration" do
          service.perform

          offer_code = product.cancellation_discount_offer_code
          expect(offer_code).to be_present
          expect(offer_code.duration_in_billing_cycles).to be_nil
        end
      end

      context "when cancellation discount already exists" do
        let!(:existing_offer_code) { create(:percentage_cancellation_discount_offer_code, products: [product]) }

        it "updates the existing offer code" do
          service.perform

          existing_offer_code.reload
          expect(existing_offer_code.amount_percentage).to eq(20)
          expect(existing_offer_code.amount_cents).to be_nil
          expect(existing_offer_code.duration_in_billing_cycles).to eq(2)
        end

        context "when params are nil" do
          let(:cancellation_discount_params) { nil }

          it "marks the existing offer code as deleted" do
            service.perform

            expect(existing_offer_code.reload).to be_deleted
            expect(product.cancellation_discount_offer_code).to be_nil
          end
        end
      end
    end
  end
end
