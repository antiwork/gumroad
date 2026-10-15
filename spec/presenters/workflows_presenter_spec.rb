# frozen_string_literal: true

require "spec_helper"

describe WorkflowsPresenter do
  describe "#workflows_props" do
    let(:seller) { create(:named_seller) }
    let(:product) { create(:product, user: seller) }
    let!(:workflow1) { create(:workflow, link: product, seller:, workflow_type: Workflow::FOLLOWER_TYPE, created_at: 1.day.ago) }
    let!(:_workflow2) { create(:workflow, link: nil, seller:, workflow_type: Workflow::SELLER_TYPE, deleted_at: DateTime.current) }
    let!(:workflow3) { create(:workflow, link: product, seller:, created_at: 1.hour.ago) }
    let!(:workflow4) { create(:workflow, link: nil, seller:, workflow_type: Workflow::SELLER_TYPE, created_at: 2.hours.ago) }

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

    context "when workflows have emails" do
      before do
        [workflow1, workflow3].each do |workflow|
          2.times { |i| create(:workflow_installment, seller:, link: product, workflow:, name: "#{workflow.id} email #{i}") }
        end
      end

      it "returns the same emails as loading each workflow on its own" do
        result = described_class.new(seller:).workflows_props

        expect(result[:workflows].map { _1[:installments].size }).to eq([2, 0, 2])
        expect(result[:workflows]).to eq([workflow3, workflow4, workflow1].map { WorkflowPresenter.new(seller:, workflow: _1).workflow_props })
      end

      it "loads emails and their open counts without a query or DynamoDB read per workflow" do
        described_class.new(seller:).workflows_props
        three_workflows = count_queries { described_class.new(seller:).workflows_props }

        2.times do
          workflow = create(:workflow, link: create(:product, user: seller), seller:)
          create(:workflow_installment, seller:, link: workflow.link, workflow:)
        end

        expect(EmailEngagementDynamoStore).not_to receive(:summary)
        expect(EmailEngagementDynamoStore).to receive(:summaries).once.and_call_original
        expect(count_queries { described_class.new(seller:).workflows_props }).to eq(three_workflows)
      end
    end
  end
end
