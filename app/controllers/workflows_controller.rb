# frozen_string_literal: true

class WorkflowsController < Sellers::BaseController
  before_action :set_workflow, only: %i[edit update destroy]
  before_action :authorize_workflow, only: %i[edit update destroy]

  layout "inertia"

  def index
    authorize Workflow
    create_user_event("workflows_view")

    workflows_presenter = WorkflowsPresenter.new(seller: current_seller)
    render inertia: "Workflows/Index", props: workflows_presenter.workflows_props
  end

  def new
    authorize Workflow

    workflow_presenter = WorkflowPresenter.new(seller: current_seller)
    render inertia: "Workflows/New", props: {
      context: -> { workflow_presenter.workflow_form_context_props },
    }
  end

  def edit
    workflow_presenter = WorkflowPresenter.new(seller: current_seller, workflow: @workflow)
    render inertia: "Workflows/Edit", props: {
      workflow: -> { workflow_presenter.workflow_props },
      context: -> { workflow_presenter.workflow_form_context_props },
    }
  end

  def create
    authorize Workflow

    success, message = save_workflow
    if success
      redirect_to workflow_emails_path(@workflow.external_id), notice: "Workflow created successfully!"
    else
      workflow_presenter = WorkflowPresenter.new(seller: current_seller, workflow: @workflow)
      render inertia: "Workflows/New", props: {
        context: -> { workflow_presenter.workflow_form_context_props },
        errors: message,
      }, status: :unprocessable_entity
    end
  end

  def update
    success, message = save_workflow
    if success
      # For publish/unpublish actions, stay on edit page; otherwise go to emails page
      if ["save_and_publish", "unpublish"].include?(workflow_params[:save_action_name])
        notice_message = workflow_params[:save_action_name] == "save_and_publish" ? "Workflow published!" : "Unpublished!"
        redirect_to edit_workflow_path(@workflow.external_id), notice: notice_message
      else
        redirect_to workflow_emails_path(@workflow.external_id), notice: "Changes saved!"
      end
    else
      workflow_presenter = WorkflowPresenter.new(seller: current_seller, workflow: @workflow)
      render inertia: "Workflows/Edit", props: {
        workflow: -> { workflow_presenter.workflow_props },
        context: -> { workflow_presenter.workflow_form_context_props },
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
      permalink = workflow_params[:permalink]
      @product = current_seller.products.visible.find_by(unique_permalink: permalink) ||
                 current_seller.products.visible.find_by(custom_permalink: permalink)
      e404 unless @product
    end
end
