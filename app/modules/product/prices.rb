# frozen_string_literal: true

module Product::Prices
  include BasePrice::Shared

  # Public: Alias for default_price_cents in order to hide the price_cents column, which isn't used anymore in favor of the Price model.
  def price_cents
    default_price_cents
  end

  # Public: Returns a single price for the product that can be used in generic situations where rent vs. buy is not indicated.
  def default_price_cents
    rent_only? ? rental_price_cents : buy_price_cents
  end

  def buy_price_cents
    # Do not query for the associated Price objects if the product isn't persisted yet since those will always return empty results.
    # All products are created with a price_cents and this attribute should be read until the product is persisted, after which the
    # associated Price(s) determine the product's price(s).
    return read_attribute(:price_cents) unless persisted?
    return default_price.price_cents if buyable? && default_price

    nil
  end

  def rental_price_cents
    return read_attribute(:rental_price_cents) unless persisted?

    rentable? ? prices_for_currency.select(&:is_rental?).last&.price_cents : nil
  end

  def default_price
    return prices_for_currency.select(&:is_rental?).last if rent_only?

    relevant_prices = prices_for_currency.select(&:is_buy?)
    relevant_prices = relevant_prices.select(&:is_default_recurrence?) if is_recurring_billing && subscription_duration.present?
    relevant_prices.last
  end

  # Public: Sets the buy price of the product to price_cents. If the product is already persisted then it changes the Price(s) associated with the
  # product to achieve that. If the product hasn't been persisted yet it simply sets the price_cents attribute and relies on associate_price to
  # create and associated the proper Price(s) object. If the product is a tiered membership product, it does not create or update a new price since
  # these prices are set on the variant.
  def price_cents=(price_cents)
    if price_cents.present? && price_cents.to_i > BasePrice::Shared::MAX_PRICE_CENTS
      errors.add(:base, "Sorry, the price entered is too large.")
      raise Link::LinkInvalid, "Sorry, the price entered is too large."
    end

    return super(price_cents) if !persisted? || is_tiered_membership

    create_or_update_new_price!(price_cents:, recurrence: subscription_duration.try(:to_s), is_rental: rent_only?)
  end

  def rental_price_cents=(rental_price_cents)
    return super(rental_price_cents) unless persisted?

    create_or_update_new_price!(price_cents: rental_price_cents, recurrence: subscription_duration.try(:to_s), is_rental: true)
  end

  def set_customizable_price
    return if is_tiered_membership
    return unless default_price_cents == 0
    # Coffee is deliberately $0-base with paid "Suggested Amounts" variants and a free-entry box
    # (initialize_suggested_amount_if_needed! sets both in one write), so the clear below would
    # undo it. Above the paid-variant branch, matching the pre-existing behaviour: coffee always
    # trips that branch, so it never reached the set either.
    return if native_type == Link::NATIVE_TYPE_COFFEE
    # Clearing, not returning: a $0-base product that gains a paid variant keeps the stale
    # `true` otherwise, and no editor control switches PWYW off on a $0 base — so checkout
    # offers a free-entry amount box whose minimum on the free option is 0 and a buyer can
    # pay full price for the free tier (gumroad-private#1660).
    if variant_categories_alive.joins(:variants).merge(BaseVariant.alive).sum("base_variants.price_difference_cents") > 0
      write_customizable_price_column(false)
      return
    end
    write_customizable_price_column(true)
  end

  def price_range=(price)
    return unless price

    price_string = price.to_s
    self.price_cents = clean_price(price_string)
    write_customizable_price(price_string)
  end

  def rental_price_range=(rental_price_string)
    self.rental_price_cents = rental_price_string.present? ? clean_price(rental_price_string) : nil
    write_customizable_price(rental_price_string) if rent_only?
  end

  def suggested_price=(price)
    self.suggested_price_cents = price.present? ? clean_price(price.to_s) : nil
  end

  def format_price(price)
    price == "$0.99" ? "99¢" : price
  end

  def price_formatted
    format_price(display_price)
  end

  def rental_price_formatted
    format_price(rental_display_price)
  end

  # `for_default_duration` quotes the product the way the native card does: amount AND
  # recurrence wording from the default duration (passing the flag to display_price_cents alone
  # pairs a default-duration amount with the cheapest tier's wording), plus the finite-term
  # forms ("once", "a month x 6") for fixed-length memberships. `discounted` takes the default
  # offer code off, which is what checkout actually charges a first-time buyer.
  def price_formatted_verbose(for_default_duration: false, discounted: false)
    price_cents = display_price_cents(for_default_duration:)
    price_cents = discounted_price_cents(price_cents) if discounted
    price_formatted_verbose_for_price_cents(
      price_cents,
      recurrence: for_default_duration ? subscription_duration : display_recurrence,
      duration_in_months: for_default_duration ? duration_in_months : nil
    )
  end

  # price_formatted_verbose over an arbitrary amount, for surfaces that show a price other than
  # the product's set one (a default-offer-code discount, say) and still need the "+" and
  # recurrence wording that make the number read correctly.
  #
  # Pass `recurrence:` when the amount came from a specific duration rather than from
  # display_price_cents: the default display_recurrence is the *cheapest* tier's recurrence, so
  # labelling a default-duration amount with it quotes a monthly price as a yearly one.
  # Pass `duration_in_months:` to engage the finite-term wording the native card renders
  # ("once" for a single-charge term, "a month x 6" for a longer fixed one); nil keeps the
  # open-ended label every existing caller shows today.
  def price_formatted_verbose_for_price_cents(price_cents, recurrence: display_recurrence, duration_in_months: nil)
    formatted = format_price(display_price_for_price_cents(price_cents))
    "#{formatted}#{show_customizable_price_indicator? ? '+' : ''}#{is_recurring_billing ? " #{recurrence_label(recurrence, duration_in_months)}" : ''}"
  end

  def price_formatted_including_rental_verbose
    return price_formatted_verbose unless buy_and_rent?

    "#{rental_price_formatted}#{show_customizable_price_indicator? ? '+' : ''} / #{price_formatted}#{show_customizable_price_indicator? ? '+' : ''}"
  end

  def suggested_price_formatted
    attrs = { no_cents_if_whole: true, symbol: false }
    MoneyFormatter.format(suggested_price_cents, price_currency_type.to_sym, attrs)
  end

  def base_price_formatted_without_dollar_sign
    display_price_for_price_cents(display_base_price_cents, symbol: false)
  end

  def price_formatted_without_dollar_sign
    display_price(symbol: false)
  end

  def rental_price_formatted_without_dollar_sign
    MoneyFormatter.format(rental_price_cents, price_currency_type.to_sym, no_cents_if_whole: true, symbol: false)
  end

  def currency_symbol
    symbol_for(price_currency_type)
  end

  def currency
    CURRENCY_CHOICES[price_currency_type]
  end

  def min_price_formatted
    MoneyFormatter.format(currency["min_price"], price_currency_type.to_sym, no_cents_if_whole: true, symbol: true)
  end

  # used by links_controller and api/links_controller to validate the price of the product against all its offer codes
  # if more routes open up to change product price, make sure to wrap in transaction and use this method
  def validate_product_price_against_all_offer_codes?
    all_alive_offer_codes = product_and_universal_offer_codes
    all_alive_offer_codes.each do |offer_code|
      next if offer_code.is_amount_valid?(self)

      errors.add(:base, "An existing discount code puts the price of this product below the #{min_price_formatted} minimum after discount.")
      return false
    end
    true
  end

  def suggested_price_greater_than_price
    return if suggested_price_cents.blank? || !customizable_price || default_price_cents.nil? || suggested_price_cents >= default_price_cents

    errors.add(:base, "The suggested price you entered was too low.")
  end

  def write_customizable_price(price_string)
    return if is_tiered_membership
    price_customizable = price_string[-1, 1] == "+" || price_cents == 0
    self.customizable_price = price_customizable
  end

  def display_base_price_cents
    is_tiered_membership ? (lowest_tier_price.price_cents || 0) : default_price_cents
  end

  def display_price_cents(for_default_duration: false)
    if is_tiered_membership?
      lowest_tier_price(for_default_duration:).price_cents || 0
    else
      # default_price_cents can be nil for a persisted product whose Price
      # records are missing or all deleted (bad/partial data). Degrade to 0 so
      # listing pages (e.g. the seller's products dashboard) render instead of
      # raising NoMethodError on nil + integer.
      (default_price_cents || 0) + (lowest_variant_price_difference_cents || 0)
    end
  end

  # The default offer code taken off a base price, which is what a buyer would be charged
  # buying one of this product right now. A surface showing a lower number quotes a price
  # checkout will not honour, so every code the default one-product checkout rejects is left on
  # the shelf: existing-customers-only (a first-time visitor does not get it), a quantity
  # minimum above one (the native page shows the quantity-1 price undiscounted for those, per
  # ProductPresenter::ProductProps#discounted_price_cents), a spend minimum this product alone
  # cannot meet (Purchase::CreateService raises below it), and a spent use cap. Erring the
  # other way is safe — a buyer who qualifies later sees the price drop at checkout, where the
  # binding amount is minted. PPP stays out entirely: it needs per-cart context.
  def discounted_price_cents(base_price_cents)
    offer_code = default_offer_code
    return base_price_cents if offer_code.blank? || offer_code.deleted? || offer_code.inactive? || offer_code.existing_customers_only?
    # A fixed-cents code stops matching after a product currency change; checkout's
    # find_offer_code refuses that pair, so the quote must too.
    return base_price_cents unless offer_code.is_currency_valid?(self)
    return base_price_cents if offer_code.minimum_quantity.to_i > 1
    return base_price_cents if offer_code.minimum_amount_cents.to_i > base_price_cents
    return base_price_cents unless default_offer_code_uses_left?(offer_code)

    [base_price_cents - offer_code.amount_off(base_price_cents), 0].max
  end

  def display_price(additional_attrs = {})
    display_price_for_price_cents(display_price_cents, additional_attrs)
  end

  def rental_display_price(additional_attrs = {})
    display_price_for_price_cents(rental_price_cents, additional_attrs)
  end

  def display_price_for_price_cents(price_cents, additional_attrs = {})
    attrs = { no_cents_if_whole: true, symbol: true }.merge(additional_attrs)
    MoneyFormatter.format(price_cents, price_currency_type.to_sym, attrs)
  end

  def price_for_recurrence(recurrence)
    prices.alive.is_buy.where(recurrence:).last
  end

  def price_cents_for_recurrence(recurrence)
    price_for_recurrence(recurrence).try(:price_cents)
  end

  def price_formatted_without_dollar_sign_for_recurrence(recurrence)
    price_cents = price_cents_for_recurrence(recurrence)
    return "" if price_cents.blank?

    display_price_for_price_cents(price_cents, symbol: false)
  end

  def has_price_for_recurrence?(recurrence)
    price_for_recurrence(recurrence).present?
  end

  def suggested_price_formatted_without_dollar_sign_for_recurrence(recurrence)
    suggested_price_cents = suggested_price_cents_for_recurrence(recurrence)
    return nil if suggested_price_cents.blank?

    display_price_for_price_cents(suggested_price_cents, symbol: false)
  end

  def save_subscription_prices_and_duration!(recurrence_price_values:, subscription_duration:)
    ActiveRecord::Base.transaction do
      self.subscription_duration = subscription_duration

      enabled_recurrences = recurrence_price_values.select { |_, attributes| attributes[:enabled].to_s == "true" }

      unless subscription_duration.to_s.in?(enabled_recurrences)
        errors.add(:base, "Please provide a price for the default payment option.")
        raise Link::LinkInvalid
      end

      save_recurring_prices!(recurrence_price_values)
    end
  end

  def has_multiple_recurrences?
    return false unless is_recurring_billing

    prices.alive.is_buy.select(:recurrence).distinct.count > 1
  end

  def available_price_cents
    available_prices =
      if is_tiered_membership?
        VariantPrice.where(variant_id: tiers.pluck(:id)).alive.is_buy.pluck(:price_cents)
      elsif current_base_variants.present?
        base_price = default_price_cents
        current_base_variants.pluck(:price_difference_cents).map { |difference| base_price + difference.to_i }
      else
        if rent_only?
          prices.alive.is_rental.where(currency: price_currency_type).pluck(:price_cents)
        else
          prices.alive.is_buy.pluck(:price_cents)
        end
      end

    available_prices.uniq
  end

  private
    # Returns the alive prices matching the product's current `price_currency_type`.
    # Filters in memory when `alive_prices` is already preloaded (the read path used by
    # ProductPresenter::Card / CardForWeb), and falls back to a `.where` when it isn't.
    # The `loaded?` guard is required: callers like the test helper
    # `change_membership_product_currency_to` do `prices.update_all(currency: ...)`
    # which mutates the DB rows without invalidating the in-memory cache, so an
    # unconditional in-memory `select` would see stale data and validation
    # (`default_price` returning nil) would fail.
    def prices_for_currency
      if association(:alive_prices).loaded?
        alive_prices.select { |p| p.currency == price_currency_type }
      else
        alive_prices.where(currency: price_currency_type)
      end
    end

    def write_customizable_price_column(value)
      return if customizable_price? == value
      # update_column skips the before_update hook that refreshes the search index, and
      # customizable_price is an indexed field PriceCheckerService filters on — so the
      # refresh has to be requested by hand.
      update_column(:customizable_price, value)
      enqueue_index_update_for(["customizable_price"])
    end

    # Private: Called only on create to instantiate Price object(s) and associate it to the newly created product.
    def associate_price
      # for tiered memberships, price is set at the tier level
      return if is_tiered_membership

      price_cents = read_attribute(:price_cents)
      if price_cents.blank?
        errors.add(:base, "New products should be created with a price")
        raise Link::LinkInvalid
      end

      price = Price.new
      price.price_cents = price_cents
      price.recurrence = subscription_duration.try(:to_s)
      price.currency = price_currency_type
      prices << price

      return unless rentable?

      rental_price_cents = read_attribute(:rental_price_cents)
      rental_price = Price.new
      rental_price.price_cents = rental_price_cents
      rental_price.currency = price_currency_type
      rental_price.is_rental = true
      prices << rental_price
    end

    def delete_unused_prices
      if buy_only?
        prices.alive.is_rental.each(&:mark_deleted!)
      elsif rent_only?
        prices.alive.is_buy.each(&:mark_deleted!)
      end
    end

    def suggested_price_cents_for_recurrence(recurrence)
      suggested_price_cents = price_cents_for_recurrence(recurrence)
      return suggested_price_cents if suggested_price_cents.present?

      default_price = self.default_price
      return nil if default_price.blank?

      number_of_months_in_default_price_recurrence = BasePrice::Recurrence.number_of_months_in_recurrence(default_price.recurrence)
      default_price_cents = default_price.price_cents
      number_of_months_in_recurrence = BasePrice::Recurrence.number_of_months_in_recurrence(recurrence)
      suggested_price_cents = (default_price_cents / number_of_months_in_default_price_recurrence.to_f) * number_of_months_in_recurrence
      suggested_price_cents
    end

    # The uses-left read is a purchases aggregate, so it runs only for capped codes and its
    # result is shared across every card on the page that carries the same default code
    # (Current resets between requests, so a redemption is reflected on the next one).
    # Every cap is checked, however large: the aggregate ranges the offer_code_id index over
    # redemptions actually made, not over the cap, so a millions-high "unlimited" cap with a
    # handful of sales costs what a cap of ten does — and checkout pays this same read on every
    # attempt. Pages::ProductPrices, which prices up to 100 products uncached, seeds this memo
    # in one grouped query (OfferCode.uses_left_by_id).
    def default_offer_code_uses_left?(offer_code)
      return true if offer_code.max_purchase_count.nil?

      cache = (Current.default_offer_code_uses_left ||= {})
      return cache[offer_code.id] if cache.key?(offer_code.id)

      cache[offer_code.id] = offer_code.is_valid_for_purchase?
    end

    def show_customizable_price_indicator?
      return customizable_price unless is_tiered_membership

      # for tiered products, show `+` in formatted price if:
      # 1. there are multiple tiers, or
      # 2. any tiers have PWYW enabled, or
      # 3. there's only 1 tier but it has multiple prices
      any_customizable =
        if association(:tiers).loaded?
          tiers.any?(&:customizable_price?)
        else
          tiers.where(customizable_price: true).exists?
        end
      multiple_tier_prices =
        if default_tier.present? && default_tier.association(:alive_prices).loaded?
          default_tier.alive_prices.count(&:is_buy?) > 1
        else
          default_tier.present? && default_tier.prices.alive.is_buy.size > 1
        end
      tiers.size > 1 || any_customizable || multiple_tier_prices
    end

    def lowest_tier_price(for_default_duration: false)
      return unless is_tiered_membership

      lowest =
        if association(:tiers).loaded? && tiers.all? { |t| t.association(:alive_prices).loaded? }
          candidates = tiers.flat_map(&:alive_prices).select(&:is_buy?)
          candidates = candidates.select { |p| p.recurrence == subscription_duration } if for_default_duration
          candidates.min_by(&:price_cents)
        else
          relation = VariantPrice.where(variant_id: tiers.map(&:id)).alive.is_buy
          relation = relation.where(recurrence: subscription_duration) if for_default_duration
          relation.order("price_cents asc").take
        end

      lowest ||
        default_tier&.prices&.is_buy&.build(price_cents: 0, recurrence: subscription_duration) ||
        VariantPrice.new(price_cents: 0, recurrence: subscription_duration)
    end

    def lowest_variant_price_difference_cents
      return if is_tiered_membership?
      # Mirrors `current_base_variants`: SKUs attached directly to the link
      # (default SKU has price_difference_cents: 0 for physical products) plus
      # alive variants under each alive variant category. Walks preloaded
      # associations when available to avoid N+1; otherwise falls through to
      # a single batched aggregate so non-card callers
      # (DashboardProductsPagePresenter#display_price_cents,
      # CollabProductsPagePresenter#display_price_cents,
      # Product::StructuredData#minimum_offer_price_cents) don't pay a
      # per-category N+1.
      preloaded_skus =
        if association(:skus_alive).loaded?
          skus_alive.to_a
        elsif association(:skus).loaded?
          skus.select(&:alive?)
        end

      if preloaded_skus &&
         association(:variant_categories_alive).loaded? &&
         variant_categories_alive.all? { |c| c.association(:alive_variants).loaded? }
        candidates = preloaded_skus + variant_categories_alive.flat_map(&:alive_variants)
        candidates.map(&:price_difference_cents).compact.min
      else
        current_base_variants.minimum(:price_difference_cents)
      end
    end

    def display_recurrence
      is_tiered_membership && lowest_tier_price ? lowest_tier_price.recurrence : subscription_duration
    end

    def prices_to_validate
      if persisted?
        prices.alive.where(currency: price_currency_type).pluck(:price_cents)
      else
        price_cents_to_validate = []
        price_cents_to_validate << buy_price_cents if buyable?
        price_cents_to_validate << rental_price_cents if rentable?
        price_cents_to_validate
      end
    end
end
