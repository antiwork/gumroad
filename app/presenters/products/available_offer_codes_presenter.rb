# frozen_string_literal: true

class Products::AvailableOfferCodesPresenter
  attr_reader :offer_codes

  def initialize(offer_codes: [])
    @offer_codes = offer_codes
  end

  def offer_codes_props
    offer_codes.map { |offer_code| offer_code_props(offer_code) }
  end

  private
    def offer_code_props(offer_code)
      {
        id: offer_code.external_id,
        code: offer_code.code,
        name: offer_code.name.presence || "",
        discount: offer_code.discount,
      }
    end
end
