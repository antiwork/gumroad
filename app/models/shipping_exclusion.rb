# frozen_string_literal: true

# A country a physical product must not ship to even when a catch-all destination
# (ELSEWHERE, or a virtual region such as NORTH AMERICA) would otherwise include it.
class ShippingExclusion < ApplicationRecord
  belongs_to :link

  validates_uniqueness_of :country_code, scope: :link_id
  validate :country_code_must_be_excludable

  after_commit :invalidate_product_cache

  # Only concrete countries can be excluded: excluding a virtual region or ELSEWHERE
  # describes a different coverage list rather than an exception to one.
  def self.excludable_country_codes
    @_excludable_country_codes ||= begin
      destinations = ShippingDestination::Destinations
      (destinations.shipping_countries.keys - destinations::VIRTUAL_COUNTRY_CODES - [destinations::ELSEWHERE]).freeze
    end
  end

  private
    def country_code_must_be_excludable
      return if country_code.blank? || self.class.excludable_country_codes.include?(country_code)

      errors.add(:country_code, "is not a country that can be excluded")
    end

    def invalidate_product_cache
      link.invalidate_cache if link.present?
    end
end
