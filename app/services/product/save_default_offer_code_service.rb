# frozen_string_literal: true

class Product::SaveDefaultOfferCodeService
  attr_reader :product, :offer_code_id

  def initialize(product, offer_code_id)
    @product = product
    @offer_code_id = offer_code_id
  end

  def perform
    if offer_code_id.blank?
      product.update!(default_offer_code_id: nil)
      return
    end

    offer_code = product.find_offer_code_by_external_id(offer_code_id)

    raise ActiveRecord::RecordNotFound, "Offer code not found" unless offer_code&.alive?
    raise ArgumentError, "Offer code is not applicable to this product" unless offer_code.applicable?(product)

    product.update!(default_offer_code_id: offer_code.id)
  end
end
