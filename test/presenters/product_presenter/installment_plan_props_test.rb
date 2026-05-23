# frozen_string_literal: true

require "test_helper"

class ProductPresenterInstallmentPlanPropsTest < ActiveSupport::TestCase
  self.described_class = ProductPresenter::InstallmentPlanProps



  context_ ProductPresenter::InstallmentPlanProps do
    let(:product) { create(:product, price_cents: 1000) }
    let(:presenter) { described_class.new(product: product) }

  context_ "#props" do
  context_ "when product has no installment plan" do
  test "returns correct props" do
          product.installment_plan&.destroy!

          expect(presenter.props).to eq(
            eligible_for_installment_plans: true,
            allow_installment_plan: false,
            installment_plan: nil
          )
        end
      end

  context_ "when product has an installment plan" do
        let!(:installment_plan) do
          create(:product_installment_plan, link: product, number_of_installments: 2, recurrence: "monthly")
        end

  test "returns correct props with installment plan details" do
          expect(presenter.props).to eq(
            eligible_for_installment_plans: true,
            allow_installment_plan: true,
            installment_plan: {
              number_of_installments: 2,
              recurrence: "monthly"
            }
          )
        end
      end

  context_ "when product is not eligible for installment plans" do
        let(:product) { create(:membership_product) }

  test "returns correct props" do
          expect(presenter.props).to eq(
            eligible_for_installment_plans: false,
            allow_installment_plan: false,
            installment_plan: nil
          )
        end
      end
    end
  end
end
