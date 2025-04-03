# frozen_string_literal: true

module Variant::Prices
  include BasePrice::Shared

  delegate :price_currency_type,
           :single_unit_currency?,
           :enqueue_index_update_for, to: :link

  def save_recurring_prices!(recurrence_price_values)
    ActiveRecord::Base.transaction do
      super(recurrence_price_values)

      # create prices for product with price_cents == 0
      product_recurrence_price_values = recurrence_price_values.each_with_object({}) do |(recurrence, recurrence_attributes), values|
        product_recurrence_attributes = recurrence_attributes.dup
        # TODO: :product_edit_react cleanup
        product_recurrence_attributes[:price] = "0" if recurrence_attributes[:price].present?
        product_recurrence_attributes[:price_cents] = 0 if recurrence_attributes[:price_cents].present?
        product_recurrence_attributes[:suggested_price] = "0" if recurrence_attributes[:suggested_price].present?
        product_recurrence_attributes[:suggested_price_cents] = 0 if recurrence_attributes[:suggested_price_cents].present?
        values[recurrence] = product_recurrence_attributes
      end
      link.save_recurring_prices!(product_recurrence_price_values)
    end
  end

  def set_customizable_price
    return unless link && link.is_tiered_membership
    return if prices.alive.length == 0 || prices.alive.where("price_cents > 0").exists?
    update_column(:customizable_price, true)
  end

  def price_must_be_within_range
    return unless variant_category.present? && link.present?
    super
  end
end
