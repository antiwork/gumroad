# frozen_string_literal: true

class Api::Internal::TaxDocumentsController < Api::Internal::BaseController
  before_action :authenticate_user!
  before_action :ensure_tax_center_enabled
  after_action :verify_authorized

  def index
    authorize :balance

    year = params[:year]&.to_i || Time.current.year - 1

    tax_center_presenter = TaxCenterPresenter.new(seller: current_seller, year:)

    render json: tax_center_presenter.props
  end

  private
    def ensure_tax_center_enabled
      return if Feature.active?(:tax_center, current_seller)

      render json: { success: false, error: "Tax center is not enabled for your account." }, status: :unauthorized
    end
end
