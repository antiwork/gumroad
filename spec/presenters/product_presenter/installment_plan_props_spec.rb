# frozen_string_literal: true

require "spec_helper"

RSpec.describe ProductPresenter::InstallmentPlanProps do
  let(:product) { create(:product, price_cents: 1000) }
  let(:presenter) { described_class.new(product: product) }

  describe "#props" do
    context "when product has no installment plan" do
      it "returns correct props" do
        product.installment_plan&.destroy!

        expect(presenter.props).to eq(
          eligible_for_installment_plans: true,
          allow_installment_plan: false,
          installment_plan: nil
        )
      end
    end

    context "when product has an installment plan" do
      let!(:installment_plan) do
        create(:product_installment_plan, link: product, number_of_installments: 2, recurrence: "monthly")
      end

      it "returns correct props with installment plan details" do
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

    context "when product is not eligible for installment plans" do
      let(:product) { create(:membership_product) }

      it "returns correct props" do
        expect(presenter.props).to eq(
          eligible_for_installment_plans: false,
          allow_installment_plan: false,
          installment_plan: nil
        )
      end
    end
  end
end
