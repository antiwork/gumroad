# frozen_string_literal: true

class ShipmentsController < ApplicationController
  before_action :authenticate_user!, only: [:mark_as_shipped]
  before_action :set_purchase, only: [:mark_as_shipped]
  after_action :verify_authorized, only: [:mark_as_shipped]

  EASYPOST_ERROR_FIELD_MAPPING = {
    "street1" => "street",
    "city" => "city",
    "state" => "state",
    "zip" => "zip_code",
    "country" => "country"
  }.freeze

  def verify_shipping_address
    easy_post = EasyPost::Client.new(api_key: GlobalConfig.get("EASYPOST_API_KEY"))
    address = easy_post.address.create(
      verify: ["delivery"],
      street1: params.require(:street_address),
      city: params.require(:city),
      state: params.require(:state),
      zip: params.require(:zip_code),
      country: params.require(:country)
    )
    if address.present?
      if address.verifications.delivery.success && address.verifications.delivery.errors.empty?
        render_address_response(address)
      else
        error = address.verifications.delivery.errors.first
        if error.code.match?(/HOUSE_NUMBER.MISSING|STREET.MISSING|BOX_NUMBER.MISSING|SECONDARY_INFORMATION.MISSING/)
          render_error("Is this your street address? You might be missing an apartment, suite, or box number.")
        else
          render_error("We are unable to verify your shipping address. Is your address correct?")
        end
      end
    else
      render_error("We are unable to verify your shipping address. Is your address correct?")
    end
  rescue EasyPost::Errors::EasyPostError
    render_error("We are unable to verify your shipping address. Is your address correct?")
  end

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

  private
    def render_error(error_message)
      render json: { success: false, error_message: }
    end

    def render_address_response(address)
      if address_unchanged?(address)
        render json: { success: true,
                       street_address: address.street1,
                       city: address.city,
                       state: address.state,
                       zip_code: formatted_zip_for(address) }
      else
        render json: { success: false,
                       easypost_verification_required: true,
                       street_address: address.street1,
                       city: address.city,
                       state: address.state,
                       zip_code: formatted_zip_for(address),
                       formatted_address: formatted_address(address),
                       formatted_original_address: formatted_address(original_address) }
      end
    end

    # Address suggestion and formatting helpers

    def formatted_address(address)
      # For street address cannot use titlecase directly on string,
      # since "17th st", gets converted to "17 Th St", instead of "17th St".
      street = address[:street1].split.map(&:capitalize).join(" ")
      city = address[:city].titleize
      zip = formatted_zip_for(address)
      state = formatted_state_for(address)
      "#{street}, #{city}, #{state}, #{zip}"
    end

    def address_unchanged?(address)
      updated_zip = formatted_zip_for(address)
      original_zip = formatted_zip_for(original_address)

      match_field_for(original_address, address, :street1) &&
          match_field_for(original_address, address, :city) &&
          match_field_for(original_address, address, :state) &&
          updated_zip == original_zip
    end

    def match_field_for(old_addr, new_addr, field)
      new_addr[field].downcase == old_addr[field].downcase
    end

    def original_address
      { street1: params[:street_address],
        city: params[:city],
        state: params[:state],
        zip: params[:zip_code],
        country: params[:country]
      }
    end

    def formatted_zip_for(address)
      in_us?(address) ? address[:zip][0..4] : address[:zip]
    end

    def formatted_state_for(address)
      in_us?(address) ? address[:state].upcase : address[:state].titleize
    end

    def in_us?(address)
      ["US", "UNITED STATES"].include?(address[:country].upcase)
    end
end
