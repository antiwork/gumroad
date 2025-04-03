# frozen_string_literal: true

class WorkflowsController < Sellers::BaseController
  before_action :set_body_id_as_app

  def index
    authorize Workflow
    create_user_event("workflows_view")
  end

  private
    def set_title
      @title = "Workflows"
    end
end
