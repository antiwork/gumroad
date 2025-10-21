# frozen_string_literal: true

class WorkflowsController < Sellers::BaseController
  before_action :set_workflow, only: %i[edit update destroy]
  before_action :authorize_workflow, only: %i[edit update destroy]

  layout "inertia"

  def index
    authorize Workflow
    create_user_event("workflows_view")

    workflows_presenter = WorkflowsPresenter.new(seller: current_seller)
    render inertia: "Workflows/Index", props: {
      # Use lambda for lazy evaluation - only evaluated when needed for partial reloads
      workflows: -> { workflows_presenter.workflows_props[:workflows] },
      context: -> { workflows_presenter.workflows_props[:context] },
    }
  end

  def new
    authorize Workflow

    workflow_presenter = WorkflowPresenter.new(seller: current_seller)
    render inertia: "Workflows/New", props: {
      # Use lambda for lazy evaluation - context has expensive product/variant queries
      context: -> { workflow_presenter.new_page_react_props[:context] },
    }
  end

  def edit
    workflow_presenter = WorkflowPresenter.new(seller: current_seller, workflow: @workflow)
    render inertia: "Workflows/Edit", props: {
      # Use lambdas for lazy evaluation
      workflow: -> { workflow_presenter.edit_page_react_props[:workflow] },
      context: -> { workflow_presenter.edit_page_react_props[:context] },
    }
  end

  def create
    authorize Workflow

    success, message = save_workflow
    if success
      redirect_to workflow_emails_path(@workflow.external_id), notice: "Workflow created successfully!"
    else
      # Stay on the same page with errors for Inertia partial reload
      workflow_presenter = WorkflowPresenter.new(seller: current_seller, workflow: @workflow)
      render inertia: "Workflows/New", props: {
        context: -> { workflow_presenter.new_page_react_props[:context] },
        errors: message,
      }, status: :unprocessable_entity
    end
  end

  def update
    success, message = save_workflow
    if success
      redirect_to workflow_emails_path(@workflow.external_id), notice: "Workflow updated successfully!"
    else
      # Stay on the same page with errors for Inertia partial reload
      workflow_presenter = WorkflowPresenter.new(seller: current_seller, workflow: @workflow)
      render inertia: "Workflows/Edit", props: {
        workflow: -> { workflow_presenter.edit_page_react_props[:workflow] },
        context: -> { workflow_presenter.edit_page_react_props[:context] },
        errors: message,
      }, status: :unprocessable_entity
    end
  end

  def destroy
    @workflow.mark_deleted!
    redirect_to workflows_path, notice: "Workflow deleted successfully!"
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

    def save_workflow
      fetch_product_and_enforce_ownership if [Workflow::PRODUCT_TYPE, Workflow::VARIANT_TYPE].include?(workflow_params[:workflow_type])

      service = Workflow::ManageService.new(seller: current_seller, params: workflow_params, product: @product, workflow: @workflow)
      @workflow ||= service.workflow
      service.process
    end

    def workflow_params
      params.require(:workflow).permit(
        :name, :workflow_type, :variant_external_id, :workflow_trigger,
        :paid_more_than, :paid_less_than, :bought_from,
        :created_after, :created_before, :permalink,
        :send_to_past_customers, :save_action_name,
        bought_products: [], not_bought_products: [], affiliate_products: [],
        bought_variants: [], not_bought_variants: [],
      )
    end


    def fetch_product_and_enforce_ownership
      @product = current_seller.products.find_by_permalink(workflow_params[:permalink])
      e404 unless @product
    end
end
