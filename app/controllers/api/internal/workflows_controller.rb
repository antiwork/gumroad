# frozen_string_literal: true

class Api::Internal::WorkflowsController < Api::Internal::BaseController
  before_action :authenticate_user!
  after_action :verify_authorized
  before_action :set_workflow, only: %i[edit update destroy save_installments]
  before_action :authorize_user, only: %i[edit update destroy save_installments]

  def index
    authorize Workflow

    render json: WorkflowsPresenter.new(seller: current_seller).workflows_props
  end

  def new
    authorize Workflow

    render json: WorkflowPresenter.new(seller: current_seller).new_page_react_props
  end

  def create
    authorize Workflow

    success, message = save_workflow
    if success
      render json: { success: true, workflow_id: @workflow.external_id }
    else
      render json: { success: false, message: }
    end
  end

  def edit
    render json: WorkflowPresenter.new(seller: current_seller, workflow: @workflow).edit_page_react_props
  end

  def update
    success, message = save_workflow
    if success
      render json: { success: true, workflow_id: @workflow.external_id }
    else
      render json: { success: false, message: }
    end
  end

  def save_installments
    service = Workflow::SaveInstallmentsService.new(seller: current_seller, params: save_installments_params, workflow: @workflow, preview_email_recipient: impersonating_user || logged_in_user)
    success, message = service.process
    if success
      edit_page_props = WorkflowPresenter.new(seller: current_seller, workflow: @workflow).edit_page_react_props
      render json: {
        success: true,
        old_and_new_installment_id_mapping: service.old_and_new_installment_id_mapping
      }.merge(edit_page_props)
    else
      render json: { success: false, message: }
    end
  end

  def destroy
    @workflow.mark_deleted!

    render json: { success: true }
  end

  private
    def set_workflow
      @workflow = current_seller.workflows.find_by_external_id(params[:id])
      return e404_json unless @workflow
      e404_json if @workflow.product_or_variant_type? && @workflow.link.user != current_seller
    end

    def authorize_user
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

    def save_installments_params
      params.require(:workflow).permit(
        :send_to_past_customers, :save_action_name,
        installments: [
          :id, :name, :message, :time_period, :time_duration, :send_preview_email,
          files: [:external_id, :url, :position, :stream_only, subtitle_files: [:url, :language]],
        ],
      )
    end
end
