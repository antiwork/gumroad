# frozen_string_literal: true

require "test_helper"

class RequestsPurchasesProductInstallmentPlanPriceProtectionTest < ActionDispatch::IntegrationTest



  context_ "Installment plan price protection" do
    let(:seller) { create(:user) }
    let(:product) { create(:product, user: seller, price_cents: 14700) }
    let(:installment_plan) { create(:product_installment_plan, link: product, number_of_installments: 3, recurrence: "monthly") }
    let(:subscription) { create(:subscription, link: product, user: seller) }
    let(:payment_option) { create(:payment_option, subscription: subscription, installment_plan: installment_plan) }

  context_ "price change protection" do
      let!(:snapshot) do
        create(:installment_plan_snapshot,
               payment_option: payment_option,
               number_of_installments: 3,
               recurrence: "monthly",
               total_price_cents: 14700)
      end

  context_ "when product price increases" do
  test "protects existing customers from price increases" do
          expect(snapshot.total_price_cents).to eq(14700)
          expect(snapshot.number_of_installments).to eq(3)

          product.update!(price_cents: 19700)
          installment_plan.reload

          snapshot.reload
          expect(snapshot.total_price_cents).to eq(14700)
          expect(snapshot.number_of_installments).to eq(3)

          payments = snapshot.calculate_installment_payment_price_cents
          expect(payments).to eq([4900, 4900, 4900])
          expect(payments.sum).to eq(14700)
        end
      end

  context_ "when product price decreases" do
  test "maintains original pricing for existing customers" do
          product.update!(price_cents: 10000)
          installment_plan.reload

          snapshot.reload
          expect(snapshot.total_price_cents).to eq(14700)

          payments = snapshot.calculate_installment_payment_price_cents
          expect(payments).to eq([4900, 4900, 4900])
          expect(payments.sum).to eq(14700)
        end
      end
    end

  context_ "installment configuration protection" do
      let!(:snapshot) do
        create(:installment_plan_snapshot,
               payment_option: payment_option,
               number_of_installments: 3,
               recurrence: "monthly",
               total_price_cents: 14700)
      end

  context_ "when installment count changes" do
  test "protects existing customers when count decreases from 3 to 2" do
          installment_plan.update!(number_of_installments: 2)

          snapshot.reload
          expect(snapshot.number_of_installments).to eq(3)

          expect(installment_plan.reload.number_of_installments).to eq(2)

          payments = snapshot.calculate_installment_payment_price_cents
          expect(payments.length).to eq(3)
          expect(payments).to eq([4900, 4900, 4900])
        end

  test "protects existing customers when count increases from 3 to 5" do
          installment_plan.update!(number_of_installments: 5)

          snapshot.reload
          expect(snapshot.number_of_installments).to eq(3)

          expect(installment_plan.reload.number_of_installments).to eq(5)

          payments = snapshot.calculate_installment_payment_price_cents
          expect(payments.length).to eq(3)
          expect(payments).to eq([4900, 4900, 4900])
        end
      end
    end
  end
end
