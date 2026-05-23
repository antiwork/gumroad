# frozen_string_literal: true

require "test_helper"

class ProductSaveCancellationDiscountServiceTest < ActiveSupport::TestCase
  self.described_class = Product::SaveCancellationDiscountService


  context_ Product::SaveCancellationDiscountService do
    let(:product) { create(:membership_product_with_preset_tiered_pricing) }
    let(:service) { described_class.new(product, cancellation_discount_params) }

  context_ "#perform" do
  context_ "with fixed amount discount" do
        let(:cancellation_discount_params) do
          {
            discount: {
              type: "fixed",
              cents: 100
            },
            duration_in_billing_cycles: 3
          }
        end

  test "creates a new fixed amount cancellation discount offer code" do
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

  context_ "when duration_in_billing_cycles is nil" do
          let(:cancellation_discount_params) do
            {
              discount: {
                type: "fixed",
                cents: 100
              },
              duration_in_billing_cycles: nil
            }
          end

  test "creates offer code with nil duration" do
            service.perform

            offer_code = product.cancellation_discount_offer_code
            expect(offer_code).to be_present
            expect(offer_code.duration_in_billing_cycles).to be_nil
          end
        end

  context_ "when cancellation discount already exists" do
          let!(:existing_offer_code) { create(:fixed_cancellation_discount_offer_code, user: product.user, products: [product]) }

  test "updates the existing offer code" do
            service.perform

            existing_offer_code.reload
            expect(existing_offer_code.amount_cents).to eq(100)
            expect(existing_offer_code.amount_percentage).to be_nil
            expect(existing_offer_code.duration_in_billing_cycles).to eq(3)
          end
        end
      end

  context_ "with percentage discount" do
        let(:cancellation_discount_params) do
          {
            discount: {
              type: "percentage",
              percents: 20
            },
            duration_in_billing_cycles: 2
          }
        end

  test "creates a new percentage cancellation discount offer code" do
          service.perform

          offer_code = product.cancellation_discount_offer_code
          expect(offer_code).to be_present
          expect(offer_code.amount_percentage).to eq(20)
          expect(offer_code.amount_cents).to be_nil
          expect(offer_code.duration_in_billing_cycles).to eq(2)
          expect(offer_code).to be_is_cancellation_discount
        end

  context_ "when duration_in_billing_cycles is nil" do
          let(:cancellation_discount_params) do
            {
              discount: {
                type: "percentage",
                percents: 20
              },
              duration_in_billing_cycles: nil
            }
          end

  test "creates offer code with nil duration" do
            service.perform

            offer_code = product.cancellation_discount_offer_code
            expect(offer_code).to be_present
            expect(offer_code.duration_in_billing_cycles).to be_nil
          end
        end

  context_ "when cancellation discount already exists" do
          let!(:existing_offer_code) { create(:percentage_cancellation_discount_offer_code, products: [product]) }

  test "updates the existing offer code" do
            service.perform

            existing_offer_code.reload
            expect(existing_offer_code.amount_percentage).to eq(20)
            expect(existing_offer_code.amount_cents).to be_nil
            expect(existing_offer_code.duration_in_billing_cycles).to eq(2)
          end

  context_ "when params are nil" do
            let(:cancellation_discount_params) { nil }

  test "marks the existing offer code as deleted" do
              service.perform

              expect(existing_offer_code.reload).to be_deleted
              expect(product.cancellation_discount_offer_code).to be_nil
            end
          end
        end
      end
    end
  end
end
