# frozen_string_literal: true

class Api::Internal::Installments::PreviewEmailsController < Api::Internal::BaseController
  before_action :authenticate_user!
  after_action :verify_authorized

  def create
    installment = current_seller.installments.alive.find_by_external_id(params[:id])
    return e404_json unless installment
    authorize installment, :preview?

    installment.send_preview_email(impersonating_user || logged_in_user)
    head :ok
  rescue Installment::PreviewEmailError => e
    render json: { message: e.message }, status: :unprocessable_entity
  end
end
