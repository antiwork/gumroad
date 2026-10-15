# frozen_string_literal: true

class BestOfferCodeService
  def initialize(product:, url_code: nil, quantity: 1, buyer: nil)
    @product = product
    @url_code = url_code.presence
    @quantity = quantity
    @buyer = buyer
    @default_codes = default_codes
  end

  def result
    return nil if @url_code.blank? && @default_codes.empty?

    url_code_result = evaluate_code(@url_code)
    default_code_result = @default_codes.lazy.map { evaluate_code(_1) }.find { _1[:valid] }

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
    # The buyer's own existing-customer default goes first; when they do not qualify, the
    # effective default (the shop-wide sale, if one runs) applies instead. evaluate_code does not
    # check currency, so a fixed default left behind by a product currency change must be skipped here.
    def default_codes
      explicit = @product.default_offer_code
      codes = [@product.effective_default_offer_code]
      codes.unshift(explicit) if explicit&.existing_customers_only? && explicit.is_currency_valid?(@product)
      codes.compact.uniq.filter_map { _1.code.presence }
    end

    def evaluate_code(code)
      return { valid: false, error_code: :missing_code } if code.blank?

      # Normalize for the lookups only; the result echoes the code as submitted
      # so URL and display state keep the buyer's original string.
      normalized_code = OfferCode.normalize_code(code)
      offer_code = @product.find_offer_code(code: normalized_code)
      return { valid: false, error_code: :invalid_offer } unless offer_code

      response = OfferCodeDiscountComputingService.new(
        normalized_code,
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
      if discount[:type] == "fixed"
        discount[:cents] * (discount[:once_per_cart] ? 1 : @quantity)
      else
        (@product.price_cents * discount[:percents] / 100.0).round * @quantity
      end
    end
end
