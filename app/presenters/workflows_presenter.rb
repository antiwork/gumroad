# frozen_string_literal: true

class WorkflowsPresenter
  def initialize(seller:)
    @seller = seller
  end

  def workflows_props
    {
      workflows: seller.workflows.alive.order("created_at DESC").map do |workflow|
        WorkflowPresenter.new(seller:, workflow:).workflow_props
      end
    }
  end

  def workflow_options_by_purchase_props(purchase)
    CustomersService.find_workflow_options_for(purchase).map { WorkflowPresenter.new(seller:, workflow: _1).workflow_option_props }
  end

  private
    attr_reader :seller
end
