# frozen_string_literal: true

class BestOfferCodeService
  def initialize(product:, url_code: nil, quantity: 1, buyer: nil, checkout_products: nil)
    @product = product
    @url_code = url_code.presence
    @quantity = quantity
    @buyer = buyer
    @checkout_products = checkout_products
    @checkout_code_savings = {}
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

    url_code_amount = @checkout_products ? @checkout_code_savings.fetch(@url_code) : amount_off_from_discount(url_code_result[:discount])
    default_code_amount = @checkout_products ? @checkout_code_savings.fetch(@default_code) : amount_off_from_discount(default_code_result[:discount])

    url_code_amount > default_code_amount ? url_code_result : default_code_result
  end

  private
    def evaluate_code(code)
      return { valid: false, error_code: :missing_code } if code.blank?

      # Normalize for the lookups only; the result echoes the code as submitted
      # so URL and display state keep the buyer's original string.
      normalized_code = OfferCode.normalize_code(code)
      offer_code = @product.find_offer_code(code: normalized_code)
      return { valid: false, error_code: :invalid_offer } unless offer_code

      response = OfferCodeDiscountComputingService.new(
        normalized_code,
        @checkout_products || {
          @product.unique_permalink => {
            permalink: @product.unique_permalink,
            quantity: [@quantity, offer_code.minimum_quantity.to_i || 0].max
          }
        },
        buyer: @buyer,
        key_by_input: !@checkout_products.nil?
      ).process

      if response[:error_code].present?
        return { valid: false, error_code: response[:error_code] }
      end

      discount = if @checkout_products
        entries = response[:products_data]
        @checkout_code_savings[code] = checkout_savings(entries)
        value = entries.values.first[:discount]
        value[:once_per_cart] ? value.merge(cents: entries.values.sum { _1[:discount][:cents] }) : value
      else
        response[:products_data][@product.unique_permalink][:discount]
      end

      {
        valid: true,
        code: code,
        discount:
      }
    end

    def checkout_savings(entries)
      entries.sum do |input_key, data|
        product = @checkout_products.fetch(input_key)
        quantity = product[:quantity].to_i
        next 0 if quantity.zero?

        discount = data[:discount]
        next discount[:cents] if discount[:once_per_cart]

        unit_price = product.fetch(:price_cents) / quantity
        amount = discount[:type] == "fixed" ? [discount[:cents], unit_price].min : (unit_price * discount[:percents] / 100.0).round
        amount * quantity
      end
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
