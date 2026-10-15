# frozen_string_literal: true

class Api::Internal::Installments::ClickedUrlsController < Api::Internal::BaseController
  before_action :authenticate_user!
  after_action :verify_authorized

  def show
    installment = current_seller.installments.alive.find_by_external_id(params[:id])
    return (skip_authorization and e404_json) unless installment
    authorize installment, :index?

    render json: { clicked_urls: InstallmentPresenter.new(seller: current_seller, installment:).clicked_urls_props }
  end
end
