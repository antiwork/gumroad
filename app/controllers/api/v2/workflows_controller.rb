# frozen_string_literal: true

class Api::V2::WorkflowsController < Api::V2::BaseController
  before_action { doorkeeper_authorize! :edit_emails }
  before_action :fetch_workflow, only: :show

  def index
    workflows = scoped_workflows.includes(:seller, :link, :base_variant).order(created_at: :desc, id: :desc).to_a
    email_counts = Installment.alive.joins(:installment_rule).where(workflow_id: workflows.map(&:id)).group(:workflow_id).count

    success_with_object(
      :workflows,
      workflows.map do |workflow|
        Api::WorkflowPresenter.new(workflow:, emails_count: email_counts.fetch(workflow.id, 0)).props
      end
    )
  end

  def show
    success_with_object(:workflow, Api::WorkflowPresenter.new(workflow: @workflow, include_emails: true).props)
  end

  private
    def scoped_workflows
      current_resource_owner.workflows.alive
    end

    def fetch_workflow
      @workflow = scoped_workflows.includes(:seller, :link, :base_variant).find_by_external_id(params[:id])
      error_with_object(:workflow, nil) if @workflow.nil?
    end
end
