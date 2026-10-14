# frozen_string_literal: true

class WorkflowsPresenter
  def initialize(seller:)
    @seller = seller
  end

  def workflows_props
    workflows = seller.workflows.alive
      .preload(:link, :base_variant, alive_installments_in_delivery_order: [:installment_rule, :ordered_alive_product_files, :link, :base_variant])
      .order("created_at DESC")
      .to_a
    Installment.preload_engagement_summaries!(workflows.flat_map(&:alive_installments_in_delivery_order))

    {
      workflows: workflows.map do |workflow|
        WorkflowPresenter.new(seller:, workflow:).workflow_props
      end
    }
  end

  private
    attr_reader :seller
end
