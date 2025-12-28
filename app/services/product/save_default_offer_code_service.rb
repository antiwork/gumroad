# frozen_string_literal: true

class Product::SaveDefaultOfferCodeService
  attr_reader :product, :offer_code_id

  def initialize(product, offer_code_id)
    @product = product
    @offer_code_id = offer_code_id
  end

  def perform
    if offer_code_id.blank?
      product.default_offer_code = nil
      return
    end

    offer_code = product.find_offer_code_by_external_id(offer_code_id)

    raise ActiveRecord::RecordNotFound, "Offer code not found" if offer_code.blank?
    raise_validation_error("Offer code is not active") if offer_code.inactive?
    raise_validation_error("Offer code has no remaining uses") if !offer_code.is_valid_for_purchase?

    product.default_offer_code = offer_code
  end

  private

  def raise_validation_error(message)
    product.errors.add(:default_offer_code, message)
    raise ActiveRecord::RecordInvalid, product
  end
end
