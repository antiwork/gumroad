# frozen_string_literal: true

class ShippingDestination < ApplicationRecord
  include CurrencyHelper
  include ShippingDestination::Destinations
  include FlagShihTzu

  belongs_to :purchase, optional: true
  belongs_to :user, optional: true
  belongs_to :link, optional: true

  has_flags 1 => :is_virtual_country,
            :column => "flags",
            :flag_query_mode => :bit_operator,
            check_for_column: false

  after_commit :invalidate_product_cache

  validates :country_code, inclusion: { in: Destinations.shipping_countries.keys }

  validates_presence_of :one_item_rate_cents
  validates_presence_of :multiple_items_rate_cents
  validates_absence_of :user_id, if: -> { link_id.present? }
  validates_absence_of :link_id, if: -> { user_id.present? }

  validates_uniqueness_of :country_code, scope: :user_id, conditions: -> { where("user_id is NOT NULL") }, case_sensitive: true
  validates_uniqueness_of :country_code, scope: :link_id, conditions: -> { where("link_id is NOT NULL") }, case_sensitive: true

  scope :alive, -> { where(deleted_at: nil) }

  # Public - Calculates the shipping amount in USD based on the quantity and the applicable shipping rate
  #
  # Quantity - Quantity of items being purchased, determines the shipping rate (one/multiple) used
  # Currency Type - The three-character string (code) representing the currency the product/shipping rate was configured in
  #
  # Returns nil if the quantity is less than 1. Returns a numeric value otherwise.
  def calculate_shipping_rate(quantity: 0, currency_type: "usd")
    return nil if quantity < 1

    shipping_rate  = get_usd_cents(currency_type, one_item_rate_cents)
    shipping_rate += get_usd_cents(currency_type, multiple_items_rate_cents * (quantity - 1))

    shipping_rate
  end

  def displayed_one_item_rate(currency_type, with_symbol: false)
    MoneyFormatter.format(one_item_rate_cents, currency_type.to_sym, no_cents_if_whole: true, symbol: with_symbol)
  end

  def displayed_multiple_items_rate(currency_type, with_symbol: false)
    MoneyFormatter.format(multiple_items_rate_cents, currency_type.to_sym, no_cents_if_whole: true, symbol: with_symbol)
  end

  def country_name
    Destinations.shipping_countries[country_code]
  end

  def self.for_product_and_country_code(product: nil, country_code: nil)
    return nil if country_code.nil? || product.nil?
    return nil unless product.is_physical

    virtual_countries = Destinations.virtual_countries_for_country_code(country_code)

    shipping_destination = product.shipping_destinations.alive.where(country_code:).first
    shipping_destination ||= product.shipping_destinations.alive.is_virtual_country.where("country_code IN (?)", virtual_countries).first
    shipping_destination ||= product.shipping_destinations.alive.where(country_code: Product::Shipping::ELSEWHERE).first

    shipping_destination
  end

  def country_or_countries
    # TODO: (Anish) make ELSEWHERE a virtual country
    if is_virtual_country || country_code == Destinations::ELSEWHERE
      case country_code
      when Destinations::EUROPE
        Destinations.europe_shipping_countries
      when Destinations::ASIA
        Destinations.asia_shipping_countries
      when Destinations::NORTH_AMERICA
        Destinations.north_america_shipping_countries
      else
        Compliance::Countries.for_select.to_h
      end
    else
      Destinations.shipping_countries.slice(country_code)
    end.reject { |code, country| Compliance::Countries.blocked?(code) }
  end

  private
    def invalidate_product_cache
      link.invalidate_cache if link.present?
    end
end
