# frozen_string_literal: true

class Workflows::InstallmentsController < Sellers::BaseController
  before_action :set_workflow
  before_action :authorize_workflow

  def update
    service = Workflow::SaveInstallmentsService.new(seller: current_seller, params: parsed_installments_params, workflow: @workflow, preview_email_recipient: impersonating_user || logged_in_user)
    success, message = service.process

    # The frontend handles the success/error messages via router.reload()
    if success
      redirect_to workflow_emails_path(@workflow.external_id)
    else
      redirect_to workflow_emails_path(@workflow.external_id), alert: message
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

    def parsed_installments_params
      # Parse JSON string from FormData if present
      workflow_params = params.require(:workflow)

      if workflow_params[:installments].is_a?(String)
        parsed_installments = JSON.parse(workflow_params[:installments])
        # Convert to hash before merging
        workflow_params_hash = workflow_params.to_unsafe_h.merge(installments: parsed_installments)
        workflow_params = ActionController::Parameters.new(workflow_params_hash)
      end

      # Permit the parameters
      workflow_params.permit(
        :send_to_past_customers, :save_action_name,
        installments: [
          :id, :name, :message, :time_period, :time_duration, :send_preview_email,
          files: [:external_id, :url, :position, :stream_only, subtitle_files: [:url, :language]],
        ],
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
