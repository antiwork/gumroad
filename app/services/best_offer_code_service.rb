# frozen_string_literal: true

class BestOfferCodeService
  # comparison_price_cents is the unit price the buyer already chose (the wanted redirect knows
  # it), and every comparison uses it. Without it the defaults are weighed on the price the card
  # quotes, and the URL code against the default on price_cents.
  def initialize(product:, url_code: nil, quantity: 1, buyer: nil, comparison_price_cents: nil)
    @product = product
    @url_code = url_code.presence
    @quantity = quantity
    @buyer = buyer
    @comparison_price_cents = comparison_price_cents
    @default_codes = default_offer_codes.filter_map { _1.code.presence }
  end

  def result
    return nil if @url_code.blank? && @default_codes.empty?

    url_code_result = evaluate_code(@url_code)
    default_code_result = best_default_code_result

    url_code_valid = url_code_result&.dig(:valid) == true
    default_code_valid = default_code_result&.dig(:valid) == true

    unless url_code_valid || default_code_valid
      return @url_code.present? ? url_code_result : nil
    end

    return url_code_result if !default_code_valid
    return default_code_result if !url_code_valid

    price_cents = @comparison_price_cents || @product.price_cents
    url_code_amount = amount_off_from_discount(url_code_result[:discount], price_cents, @quantity)
    default_code_amount = amount_off_from_discount(default_code_result[:discount], price_cents, @quantity)

    url_code_amount > default_code_amount ? url_code_result : default_code_result
  end

  # The buyer's own existing-customer default goes first, then the effective default (the shop-wide
  # sale, if one runs). evaluate_code does not check currency, so a fixed default left behind by a
  # product currency change is skipped here, including when no sale replaces it.
  def default_offer_codes
    @default_offer_codes ||= begin
      explicit = @product.default_offer_code
      codes = [@product.effective_default_offer_code]
      codes.unshift(explicit) if explicit&.existing_customers_only?
      codes.compact.uniq.select { _1.is_currency_valid?(@product) }
    end
  end

  private
    # A qualifying buyer keeps their existing-customer default only when it takes more off than the
    # shop-wide sale, so it never prices them above the sale everyone else sees; a tie keeps it.
    # Weighed on the chosen price, else the one the card quotes: a tiered membership's price_cents is 0.
    def best_default_code_result
      @default_codes.map { evaluate_code(_1) }.select { _1[:valid] }.reduce do |best, candidate|
        default_comparison_amount(candidate[:discount]) > default_comparison_amount(best[:discount]) ? candidate : best
      end
    end

    # evaluate_code lifts the quantity to the code's minimum and the preview skips the spend
    # minimum, so a code the initial quote cannot meet still comes back valid. applySelection drops
    # it at that quote, so it takes nothing off here.
    def default_comparison_amount(discount)
      price_cents = default_comparison_price_cents
      return 0 unless met_discount_conditions?(discount, price_cents)

      amount_off_from_discount(discount, price_cents, default_comparison_quantity)
    end

    # Mirrors applySelection's gate, which checks both minimums at the stock-capped quantity.
    def met_discount_conditions?(discount, price_cents)
      quantity = default_comparison_quantity
      quantity >= discount[:minimum_quantity].to_i && price_cents * quantity >= discount[:minimum_amount_cents].to_i
    end

    def default_comparison_quantity
      @default_comparison_quantity ||= [@quantity, @product.remaining_for_sale_count].compact.min
    end

    def default_comparison_price_cents
      @default_comparison_price_cents ||= @comparison_price_cents || @product.display_price_cents(for_default_duration: true)
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

    # A once-per-cart code's cents are allocated against price_cents, which is 0 on a tiered
    # membership; the page takes the configured amount off the quoted total instead.
    def amount_off_from_discount(discount, price_cents, quantity)
      return 0 unless discount
      if discount[:type] == "fixed" && discount[:once_per_cart]
        [discount[:once_per_cart_amount_cents] || discount[:cents], price_cents * quantity].min
      elsif discount[:type] == "fixed"
        [discount[:cents], price_cents].min * quantity
      else
        (price_cents * discount[:percents] / 100.0).round * quantity
      end
    end
end
