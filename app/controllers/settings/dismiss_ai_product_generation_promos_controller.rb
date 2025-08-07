# frozen_string_literal: true

class Settings::DismissAiProductGenerationPromosController < Sellers::BaseController
  before_action :authenticate_user!
  after_action :verify_authorized

  def create
    authorize current_seller, :generate_product_details_with_ai?

    current_seller.update!(dismissed_create_products_with_ai_promo_alert: true)

    head :ok
  end
end
