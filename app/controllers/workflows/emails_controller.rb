# frozen_string_literal: true

class Workflows::EmailsController < Sellers::BaseController
  before_action :set_workflow
  before_action :authorize_workflow

  layout "inertia"

  FLASH_CHANGES_SAVED = "Changes saved!"
  FLASH_WORKFLOW_PUBLISHED = "Workflow published!"
  FLASH_WORKFLOW_UNPUBLISHED = "Unpublished!"

  def index
    workflow_presenter = WorkflowPresenter.new(seller: current_seller, workflow: @workflow)
    render inertia: "Workflows/Emails/Index", props: {
      workflow: -> { workflow_presenter.workflow_props },
      context: -> { workflow_presenter.workflow_form_context_props },
    }
  end

  def update
    service = Workflow::SaveInstallmentsService.new(
      seller: current_seller,
      params: installments_params,
      workflow: @workflow,
      preview_email_recipient: preview_recipient
    )
    success, errors = service.process

    if success
      flash_message = case installments_params[:save_action_name]
      when "save_and_publish"
        FLASH_WORKFLOW_PUBLISHED
      when "save_and_unpublish"
        FLASH_WORKFLOW_UNPUBLISHED
      else
        FLASH_CHANGES_SAVED
      end

      redirect_to workflow_emails_path(@workflow.external_id), status: :see_other, notice: flash_message
    else
      error_message = errors.full_messages.first
      redirect_to workflow_emails_path(@workflow.external_id), inertia: { errors: errors }, alert: error_message
    end
  end

  private
    def set_workflow
      @workflow = current_seller.workflows.find_by_external_id(params[:workflow_id])
      return e404 unless @workflow
      e404 if @workflow.product_or_variant_type? && @workflow.link.user != current_seller
    end

    def authorize_workflow
      authorize @workflow
    end

    def preview_recipient
      impersonating_user || logged_in_user
    end

    def installments_params
      params.require(:workflow).permit(
        :send_to_past_customers, :save_action_name,
        installments: [
          :id, :name, :message, :time_period, :time_duration, :send_preview_email,
          files: [:external_id, :url, :position, :stream_only, subtitle_files: [:url, :language]],
        ],
      )
    end
end
