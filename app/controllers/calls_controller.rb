# frozen_string_literal: true

class CallsController < ApplicationController
  before_action :authenticate_user!

  def update
    @call = Call.find_by_external_id!(params[:id])
    authorize @call

    @call.update!(params.permit(policy(@call).permitted_attributes))

    head :no_content
  end
end
