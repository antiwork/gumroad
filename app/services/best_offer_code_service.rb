# frozen_string_literal: true

class BestOfferCodeService
  def initialize(product:, url_code: nil, quantity: 1, buyer: nil)
    @product = product
    @url_code = url_code.presence
    @quantity = quantity
    @buyer = buyer
    @default_code = @product.default_offer_code&.code
  end

  def result
    return nil if @url_code.blank? && @default_code.blank?

    url_code_result = evaluate_code(@url_code)
    default_code_result = evaluate_code(@default_code)

    url_code_valid = url_code_result&.dig(:valid) == true
    default_code_valid = default_code_result&.dig(:valid) == true

    unless url_code_valid || default_code_valid
      return @url_code.present? ? url_code_result : nil
    end

    return url_code_result if !default_code_valid
    return default_code_result if !url_code_valid

    url_code_amount = amount_off_from_discount(url_code_result[:discount])
    default_code_amount = amount_off_from_discount(default_code_result[:discount])

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
        },
        buyer: @buyer
      ).process

      if response[:error_code].present?
        return { valid: false, error_code: response[:error_code] }
      end

      {
        valid: true,
        code: code,
        discount: response[:products_data][@product.unique_permalink][:discount]
      }
    end

    def amount_off_from_discount(discount)
      return 0 unless discount
      transient = discount[:type] == "fixed" ?
        OfferCode.new(amount_cents: discount[:cents]) :
        OfferCode.new(amount_percentage: discount[:percents])
      transient.amount_off(@product.price_cents)
    end
end
