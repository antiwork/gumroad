# frozen_string_literal: true

class ProductPresenter::InstallmentPlanProps
  attr_reader :product, :installment_plan

  def initialize(product:)
    @product = product
    @installment_plan = product.installment_plan
  end

  def props
    {
      eligible_for_installment_plans: product.eligible_for_installment_plans?,
      allow_installment_plan: product.allow_installment_plan?,
      installment_plan: installment_plan_props
    }
  end

  private
    def installment_plan_props
      return if installment_plan.blank?

      {
        number_of_installments: installment_plan.number_of_installments,
        recurrence: installment_plan.recurrence,
      }
    end
end
