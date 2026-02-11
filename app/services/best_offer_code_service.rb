# frozen_string_literal: true

class BestOfferCodeService
  def initialize(product:, url_code: nil, quantity: 1)
    @product = product
    @url_code = url_code.presence
    @quantity = quantity
    @default_code = @product.default_offer_code&.code
  end

  def result
    return nil if @url_code.blank? && @default_code.blank?

    url_code_result = evaluate_code(@url_code)
    default_code_result = evaluate_code(@default_code)

    url_code_valid = url_code_result&.dig(:valid) == true
    default_code_valid = default_code_result&.dig(:valid) == true

    return url_code_result unless url_code_valid || default_code_valid

    return url_code_result if !default_code_valid
    return default_code_result if !url_code_valid

    # Both are valid, compare discount amounts
    url_code_amount = compute_amount_off(@url_code)
    default_code_amount = compute_amount_off(@default_code)

    url_code_amount > default_code_amount ? url_code_result : default_code_result
  end

  private
    def evaluate_code(code)
      return { valid: false, error_code: :missing_code } if code.blank?

      offer_code = @product.find_offer_code(code: code)
      return { valid: false, error_code: :invalid_offer } unless offer_code

      response = OfferCodeDiscountComputingService.new(
        code,
        {
          @product.unique_permalink => {
            permalink: @product.unique_permalink,
            quantity: [@quantity, offer_code.minimum_quantity.to_i || 0].max
          }
        }
      ).process

      if response[:error_code].present?
        return { valid: false, error_code: response[:error_code] }
      end

      {
        valid: true,
        code: code,
        discount: offer_code.discount
      }
    end

    def compute_amount_off(code)
      return 0 if code.blank?

      offer_code = @product.find_offer_code(code: code)
      return 0 unless offer_code

      offer_code.amount_off(@product.price_cents)
    end
end
