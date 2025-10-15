# frozen_string_literal: true

class WorkflowsController < Sellers::BaseController
  before_action :set_workflow, only: %i[edit emails]
  before_action :authorize_workflow, only: %i[edit emails]

  layout "inertia"

  def index
    authorize Workflow
    create_user_event("workflows_view")

    workflows_presenter = WorkflowsPresenter.new(seller: current_seller)
    render inertia: "Workflows/Index", props: workflows_presenter.workflows_props
  end

  def new
    authorize Workflow
    create_user_event("workflows_view")

    workflow_presenter = WorkflowPresenter.new(seller: current_seller)
    render inertia: "Workflows/New", props: workflow_presenter.new_page_react_props
  end

  def edit
     create_user_event("workflows_view")

    workflow_presenter = WorkflowPresenter.new(seller: current_seller, workflow: @workflow)
    render inertia: "Workflows/Edit", props: workflow_presenter.edit_page_react_props
  end

  def emails
     create_user_event("workflows_view")

    workflow_presenter = WorkflowPresenter.new(seller: current_seller, workflow: @workflow)
    render inertia: "Workflows/Emails", props: workflow_presenter.edit_page_react_props
  end

  private
    def set_title
      @title = "Workflows"
    end

    def set_workflow
      @workflow = current_seller.workflows.find_by_external_id(params[:id])
      return e404 unless @workflow
      e404 if @workflow.product_or_variant_type? && @workflow.link.user != current_seller
    end

    def authorize_workflow
      authorize @workflow
    end
end
