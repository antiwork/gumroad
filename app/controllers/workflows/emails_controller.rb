# frozen_string_literal: true

class Workflows::EmailsController < Sellers::BaseController
  before_action :set_workflow
  before_action :authorize_workflow

  layout "inertia"

  def index
    create_user_event("workflows_view")

    workflow_presenter = WorkflowPresenter.new(seller: current_seller, workflow: @workflow)
    render inertia: "Workflows/Emails", props: {
      # Use lambdas for lazy evaluation - context has expensive product/variant queries
      workflow: -> { workflow_presenter.edit_page_react_props[:workflow] },
      context: -> { workflow_presenter.edit_page_react_props[:context] },
    }
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
end
