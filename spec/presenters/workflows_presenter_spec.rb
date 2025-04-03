# frozen_string_literal: true

require "spec_helper"

describe WorkflowsPresenter do
  describe "#workflows_props" do
    let(:seller) { create(:named_seller) }
    let(:product) { create(:product, user: seller) }
    let!(:workflow1) { create(:workflow, link: product, seller:, workflow_type: Workflow::FOLLOWER_TYPE, created_at: 1.day.ago) }
    let!(:_workflow2) { create(:workflow, link: nil, seller:, workflow_type: Workflow::SELLER_TYPE, deleted_at: DateTime.current) }
    let!(:workflow3) { create(:workflow, link: product, seller:) }
    let!(:workflow4) { create(:workflow, link: nil, seller:, workflow_type: Workflow::SELLER_TYPE) }

    it "returns alive workflows ordered by created at descending" do
      result = described_class.new(seller:).workflows_props

      expect(result).to eq({
                             workflows: [
                               WorkflowPresenter.new(seller:, workflow: workflow3).workflow_props,
                               WorkflowPresenter.new(seller:, workflow: workflow4).workflow_props,
                               WorkflowPresenter.new(seller:, workflow: workflow1).workflow_props,
                             ]
                           })
    end
  end
end
