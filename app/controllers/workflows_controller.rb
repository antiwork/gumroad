# frozen_string_literal: true

class WorkflowsController < Sellers::BaseController
  before_action :set_workflow, only: %i[edit update destroy]
  before_action :authorize_workflow, only: %i[edit update destroy]
  before_action :fetch_product_and_enforce_ownership, only: %i[create update], if: :product_or_variant_workflow?

  layout "inertia"

  FLASH_CHANGES_SAVED = "Changes saved!"
  FLASH_WORKFLOW_PUBLISHED = "Workflow published!"
  FLASH_WORKFLOW_UNPUBLISHED = "Unpublished!"
  FLASH_WORKFLOW_DELETED = "Workflow deleted!"

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
      context: -> { workflow_presenter.workflow_form_context_props }
    }
  end

  def create
    authorize Workflow

    service = Workflow::ManageService.new(seller: current_seller, params: workflow_params, product: @product, workflow: nil)
    success, errors = service.process

    if success
      redirect_to workflow_emails_path(service.workflow.external_id), notice: FLASH_CHANGES_SAVED, status: :see_other
    else
      redirect_to new_workflow_path, inertia: { errors: errors }
    end
  end

  def edit
    workflow_presenter = WorkflowPresenter.new(seller: current_seller, workflow: @workflow)
    render inertia: "Workflows/Edit", props: {
      workflow: -> { workflow_presenter.workflow_props },
      context: -> { workflow_presenter.workflow_form_context_props }
    }
  end

  def update
    service = Workflow::ManageService.new(seller: current_seller, params: workflow_params, product: @product, workflow: @workflow)
    success, errors = service.process

    if success
      notice_message = case workflow_params[:save_action_name]
                       when "save_and_publish"
                         FLASH_WORKFLOW_PUBLISHED
                       when "save_and_unpublish"
                         FLASH_WORKFLOW_UNPUBLISHED
                       else
                         FLASH_CHANGES_SAVED
      end

      redirect_to workflow_emails_path(@workflow.external_id), notice: notice_message, status: :see_other
    else
      redirect_to edit_workflow_path(@workflow.external_id), inertia: { errors: { base: [errors] } }, alert: errors
    end
  end

  def destroy
    @workflow.mark_deleted!
    redirect_to workflows_path, notice: FLASH_WORKFLOW_DELETED, status: :see_other
  end

  private
    def set_default_page_title
      set_meta_tag(title: "Workflows")
    end

    def set_workflow
      @workflow = current_seller.workflows.find_by_external_id(params[:id])
      return e404 unless @workflow
      e404 if @workflow.product_or_variant_type? && @workflow.link.user != current_seller
    end

    def authorize_workflow
      authorize @workflow
    end

    def product_or_variant_workflow?
      [Workflow::PRODUCT_TYPE, Workflow::VARIANT_TYPE].include?(workflow_params[:workflow_type])
    end

    def fetch_product_and_enforce_ownership
      # Override parent method to handle workflow params structure
      permalink = workflow_params[:permalink]
      @product = current_seller.products.visible.find_by(unique_permalink: permalink) ||
                 current_seller.products.visible.find_by(custom_permalink: permalink) ||
                 e404
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
end
