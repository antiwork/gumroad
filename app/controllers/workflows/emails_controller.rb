# frozen_string_literal: true

class Workflows::EmailsController < Sellers::BaseController
  before_action :set_workflow
  before_action :authorize_workflow

  layout "inertia"

  FLASH_CHANGES_SAVED = "Changes saved!"
  FLASH_WORKFLOW_PUBLISHED = "Workflow published!"
  FLASH_WORKFLOW_UNPUBLISHED = "Workflow unpublished!"

  inertia_share do
    RenderingExtension.custom_context(view_context).merge(
      current_user: current_user_props(current_user, impersonated_user),
      authenticity_token: form_authenticity_token,
      flash: inertia_flash_props,
      title: @title
    )
  end

  def show
    workflow_presenter = WorkflowPresenter.new(seller: current_seller, workflow: @workflow)
    render inertia: "Workflows/Emails/Index", props: {
      workflow: -> { workflow_presenter.workflow_props },
      context: -> { workflow_presenter.workflow_form_context_props },
    }
  end

  def update
    service = Workflow::SaveInstallmentsService.new(seller: current_seller, params: installments_params, workflow: @workflow, preview_email_recipient: impersonating_user || logged_in_user)
    success, errors = service.process

    if success
      # Determine the flash message based on save_action_name
      flash_message = case installments_params[:save_action_name]
      when "save_and_publish"
        FLASH_WORKFLOW_PUBLISHED
      when "save_and_unpublish"
        FLASH_WORKFLOW_UNPUBLISHED
      else
        FLASH_CHANGES_SAVED
      end

      workflow_presenter = WorkflowPresenter.new(seller: current_seller, workflow: @workflow.reload)
      render inertia: "Workflows/Emails/Index", props: {
        workflow: -> { workflow_presenter.workflow_props },
        context: -> { workflow_presenter.workflow_form_context_props },
        flash: { message: flash_message, status: "success" },
      }
    else
      workflow_presenter = WorkflowPresenter.new(seller: current_seller, workflow: @workflow)
      render inertia: "Workflows/Emails/Index", props: {
        workflow: -> { workflow_presenter.workflow_props },
        context: -> { workflow_presenter.workflow_form_context_props },
      }, status: :unprocessable_entity, inertia: { errors: errors }
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
