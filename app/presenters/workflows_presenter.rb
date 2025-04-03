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

  private
    attr_reader :seller
end
