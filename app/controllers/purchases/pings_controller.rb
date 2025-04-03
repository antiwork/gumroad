# frozen_string_literal: true

class Purchases::PingsController < Sellers::BaseController
  before_action :set_purchase

  def create
    authorize [:audience, @purchase], :create_ping?

    @purchase.send_notification_webhook_from_ui

    head :no_content
  end

  private
    def set_purchase
      (@purchase = current_seller.sales.find_by_external_id(params[:purchase_id])) || e404_json
    end
end
