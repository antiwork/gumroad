# frozen_string_literal: true

class Api::Internal::Installments::AudienceCountsController < Api::Internal::BaseController
  before_action :authenticate_user!
  after_action :verify_authorized

  def show
    installment = current_seller.installments.alive.find_by_external_id(params[:id])
    return e404_json unless installment
    authorize installment, :updated_audience_count?

    render json: { count: installment.audience_members_count }
  end
end
