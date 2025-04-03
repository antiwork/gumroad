# frozen_string_literal: true

module BasePrice::Shared
  def clean_price(price_string)
    clean = price_string.to_s
    unless single_unit_currency?
      clean = clean.gsub(/[^-0-9.,]/, "")      # allow commas for now
      if clean.rindex(/,/) == clean.length - 3 # euro style!
        clean = clean.delete(".") # remove euro 1000^x delimiters
        clean = clean.tr(",", ".")             # replace euro comma with decimal
      end
    end
    clean = clean.gsub(/[^-0-9.]/, "")         # remove commas
    string_to_price_cents(price_currency_type.to_sym, clean)
  end

  def save_recurring_prices!(recurrence_price_values)
    enabled_recurrences = recurrence_price_values.select { |_, attributes| attributes[:enabled].to_s == "true" }

    enabled_recurrences.each do |recurrence, attributes|
      price = attributes[:price]
      # TODO: :product_edit_react cleanup
      if price.blank? && attributes[:price_cents].blank?
        errors.add(:base, "Please provide a price for all selected payment options.")
        raise Link::LinkInvalid
      end
      # TODO: :product_edit_react cleanup
      price_cents = attributes[:price_cents] || clean_price(price)

      suggested_price = attributes[:suggested_price]
      # TODO: :product_edit_react cleanup
      suggested_price_cents = attributes[:suggested_price_cents] || (suggested_price.present? ? clean_price(suggested_price) : nil)
      create_or_update_new_price!(
        price_cents:,
        suggested_price_cents:,
        recurrence:,
        is_rental: false
      )
    end

    recurrences_to_delete = (BasePrice::Recurrence.all - enabled_recurrences.keys.map(&:to_s)).push(nil)
    prices_to_delete = prices.alive.where(recurrence: recurrences_to_delete)
    prices_to_delete.map(&:mark_deleted!)

    enqueue_index_update_for(["price_cents", "available_price_cents"]) if prices_to_delete.any?

    save!
  end

  def price_must_be_within_range
    min_price = CURRENCY_CHOICES[price_currency_type]["min_price"]

    prices_to_validate.compact.each do |price_cents_to_validate|
      next if price_cents_to_validate == 0

      if price_cents_to_validate < min_price
        errors.add(:base, "Sorry, a product must be at least #{MoneyFormatter.format(min_price, price_currency_type.to_sym, no_cents_if_whole: true, symbol: true)}.")
      elsif user.max_product_price && get_usd_cents(price_currency_type, price_cents_to_validate) > user.max_product_price
        errors.add(:base, "Sorry, we don't support pricing products above $5,000.")
      end
    end
  end

  private
    # Private: This method checks to see if a price with the passed in recurrence, currency, and rental/buy status exists.
    # If so, it updates it with the additional properties. If not, it creates a new price.
    #
    # price_cents - The amount of the Price to be created
    # recurrence - The recurrence of the price to be created. It could be nil for non-recurring-billing products.
    # is_rental - Indicating if the newly created Price is for rentals.
    # suggested_price_cents - The suggested amount to pay if pay-what-you-want is enabled. Can be nil if PWYW is not enabled.
    #
    def create_or_update_new_price!(price_cents:, recurrence:, is_rental:, suggested_price_cents: nil)
      if is_rental && price_cents.nil?
        errors.add(:base, "Please enter the rental price.")
        raise ActiveRecord::RecordInvalid.new(self)
      end

      ActiveRecord::Base.transaction do
        scoped_prices = is_rental ? prices.alive.is_rental : prices.alive.is_buy
        scoped_prices = scoped_prices.where(currency: price_currency_type, recurrence:)

        price = scoped_prices.last || scoped_prices.new
        price.price_cents = price_cents
        price.suggested_price_cents = suggested_price_cents
        price.is_rental = is_rental
        changed = price.changed?
        begin
          price.save!
        rescue => e
          errors.add(:base, price.errors.full_messages.to_sentence)
          raise e
        end

        if changed
          alive_prices.reset
          enqueue_index_update_for(["price_cents", "available_price_cents"])
        end
      end
    end

    def prices_to_validate
      prices.alive.map(&:price_cents)
    end
end
