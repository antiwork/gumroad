# frozen_string_literal: true

class OfferCodeDiscountComputingService
  # While computing it rejects the product if quantity of the product is greater
  # than the quantity left for the offer_code for e.g. Suppose seller adds a
  # universal offer code which has 4 quantity left and a user adds three products
  # in bundle - A[2], B[3], C[1] (product names with quantity) and applies the
  # offer code. Then offer code will be applied on A[2], B[0], C[1]. It skipped B
  # because quantity of B was greater than the limit left for the offer_code.
  # Taking some more examples
  #   => A[2], B[3], C[2] --> A[2], C[2]
  #   => A[2], C[3]       --> A[2]

  def initialize(code, products, buyer: nil)
    @code = code
    @products = products || {}
    @buyer = buyer
  end

  def process
    products_data = {}

    links.each do |link|
      purchase_quantity = products[link.unique_permalink][:quantity].to_i
      offer_code = find_applicable_offer_code_for(link)

      next unless offer_code
      track_applicable_offer_code(offer_code)

      resolved_discount = offer_code.evaluate_for_buyer(buyer, product: link)

      # A fixed-amount code is an amount off the order, not off every line: applying it
      # per line multiplies the seller's intended discount by cart breadth. Once it has
      # landed on a line, later lines are skipped silently — that is the design, not an
      # ineligibility, so it must not poison error_code for the whole cart.
      #
      # Known limit: when that line costs less than the code, the remainder is dropped
      # rather than spilling onto later lines. Spilling is not expressible today —
      # purchases carry only offer_code_id, so checkout re-derives the full amount_cents
      # per line (Purchase#offer_amount_off) and a partial amount cannot be charged.
      # Closing it needs an order-level discount or a per-line amount on the purchase.
      next if once_per_cart?(offer_code) && already_applied?(offer_code)

      units = usage_units(offer_code, purchase_quantity)

      if resolved_discount && eligible?(offer_code, purchase_quantity, units)
        track_usage(offer_code, units)
        mark_applied(offer_code)
        products_data[link.unique_permalink] = { discount: resolved_discount }
        optimistically_apply_to_applicable_cross_sells(products_data, link) unless once_per_cart?(offer_code)
      else
        track_ineligibility(offer_code, purchase_quantity, units, resolved_discount)
      end
    end

    {
      products_data:,
      error_code: error_code(products_data),
      partial_ineligibility_code: partial_ineligibility_code(products_data)
    }
  end

  private
    attr_reader :code, :products, :buyer

    # Ordered by the buyer's cart, not the DB's plan: a capped code is consumed
    # greedily, so iteration order decides which lines win a scarce discount.
    def links
      @_links ||= begin
        permalinks = products.values.map { it[:permalink] }.uniq
        by_permalink = Link.visible
          .includes({ available_cross_sells: :product })
          .where(unique_permalink: permalinks)
          .index_by(&:unique_permalink)
        permalinks.filter_map { by_permalink[it] }
      end
    end

    def offer_codes
      return OfferCode.none if code.blank?

      @_offer_codes ||= OfferCode
        .includes(:products, :excluded_products)
        .where(user_id: links.map(&:user_id), code:)
        .alive
    end

    def offer_codes_by_user_id
      @_offer_codes_by_user_id ||= offer_codes.group_by(&:user_id)
    end

    def find_applicable_offer_code_for(link)
      offer_codes_by_user_id[link.user_id]
        &.find { |offer_code| offer_code.applicable?(link) }
    end

    def once_per_cart?(offer_code)
      offer_code.is_cents?
    end

    def already_applied?(offer_code)
      @applied_offer_code_ids ||= Set.new
      @applied_offer_code_ids.include?(offer_code.id)
    end

    def mark_applied(offer_code)
      @applied_offer_code_ids ||= Set.new
      @applied_offer_code_ids << offer_code.id
    end

    # How much of max_purchase_count this line spends. A fixed-amount code is applied once
    # per cart, so it costs exactly one use regardless of how many units are on the line.
    def usage_units(offer_code, purchase_quantity)
      once_per_cart?(offer_code) ? 1 : purchase_quantity
    end

    def eligible?(offer_code, purchase_quantity, units)
      return false if offer_code.inactive?
      return false unless meets_minimum_purchase_quantity?(offer_code, purchase_quantity)
      return false unless has_sufficient_times_of_use?(offer_code, units)

      true
    end

    def meets_minimum_purchase_quantity?(offer_code, purchase_quantity)
      offer_code.minimum_quantity.blank? ||
        purchase_quantity >= offer_code.minimum_quantity
    end

    def has_sufficient_times_of_use?(offer_code, purchase_quantity)
      offer_code.max_purchase_count.blank? ||
        remaining_times_of_use(offer_code) >= purchase_quantity
    end

    def remaining_times_of_use(offer_code)
      @remaining_times_of_use ||= {}
      @remaining_times_of_use[offer_code.id] ||= offer_code.quantity_left
    end

    def track_applicable_offer_code(offer_code)
      @applicable_offer_codes ||= []
      @applicable_offer_codes << offer_code
    end

    def track_usage(offer_code, purchase_quantity)
      return if offer_code.max_purchase_count.blank?

      @remaining_times_of_use[offer_code.id] -= purchase_quantity
    end

    def track_ineligibility(offer_code, purchase_quantity, units, resolved_discount)
      @product_level_ineligibilities ||= {}

      if resolved_discount.nil? && offer_code.existing_customers_only?
        @product_level_ineligibilities[:not_existing_customer] = true
      end

      unless meets_minimum_purchase_quantity?(offer_code, purchase_quantity)
        @product_level_ineligibilities[:unmet_minimum_purchase_quantity] = true
      end

      unless has_sufficient_times_of_use?(offer_code, units)
        if @remaining_times_of_use[offer_code.id].positive?
          @product_level_ineligibilities[:insufficient_times_of_use] = true
        else
          @product_level_ineligibilities[:sold_out] = true
        end
      end
    end

    PRODUCT_LEVEL_INELIGIBILITIES_BY_DISPLAY_PRIORITY = [
      :not_existing_customer,
      :unmet_minimum_purchase_quantity,
      :insufficient_times_of_use,
      :sold_out,
    ]

    def error_code(products_data)
      return :invalid_offer if @applicable_offer_codes.blank?
      return :inactive if @applicable_offer_codes.all?(&:inactive?)

      # Only fatal when nothing survived; the loop above builds a partial
      # products_data by design. Code-level rejections must stay ABOVE this guard,
      # or a surviving line will suppress them.
      return nil if products_data.present?

      highest_priority_ineligibility
    end

    # Set when SOME lines were discounted and others skipped: not an error, but
    # the reason the discount does not cover the whole cart.
    def partial_ineligibility_code(products_data)
      return nil if products_data.blank?

      highest_priority_ineligibility
    end

    def highest_priority_ineligibility
      return nil if @product_level_ineligibilities.blank?

      PRODUCT_LEVEL_INELIGIBILITIES_BY_DISPLAY_PRIORITY
        .find { @product_level_ineligibilities[it] }
    end

    # This is optimistic because additive cross-sells may not meet the minimum
    # purchase quantity or the discount code may have been used up. The discount
    # will still be validated and updated during checkout, where the buyer will
    # be able to see the correct discount and adjust accordingly.
    def optimistically_apply_to_applicable_cross_sells(products_data, link)
      link.available_cross_sells.each do |cross_sell|
        offer_code = find_applicable_offer_code_for(cross_sell.product)
        next unless offer_code

        resolved_discount = offer_code.evaluate_for_buyer(buyer, product: cross_sell.product)
        next unless resolved_discount

        products_data[cross_sell.product.unique_permalink] = { discount: resolved_discount }
      end
    end
end
