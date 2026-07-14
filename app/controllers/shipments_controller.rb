# frozen_string_literal: true

class ShipmentsController < ApplicationController
  before_action :authenticate_user!, only: [:mark_as_shipped]
  before_action :set_purchase, only: [:mark_as_shipped]
  after_action :verify_authorized, only: [:mark_as_shipped]

  def mark_as_shipped
    authorize [:audience, @purchase]

    # For old products, before we started creating shipments for any products with shipping addresses.
    shipment = Shipment.create(purchase: @purchase) if @purchase.shipment.blank?
    shipment ||= @purchase.shipment

    if params[:tracking_url]
      shipment.tracking_url = params[:tracking_url]
      shipment.save!
    end
    shipment.mark_shipped!

    head :no_content
  end

  protected
    def set_purchase
      @purchase = current_seller.sales.find_by_external_id(params[:purchase_id]) || e404_json
    end
end
