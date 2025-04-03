# frozen_string_literal: true

class ThirdPartyAnalytic < ApplicationRecord
  include ExternalId
  include Deletable

  belongs_to :user, optional: true
  belongs_to :link, optional: true

  validates :user, presence: true

  after_commit :clear_related_products_cache

  scope :universal, -> { where("link_id is null") }

  FOR_ALL_PRODUCTS = "#all_products"
  LOCATIONS = ["all", "product", "receipt"]

  class ThirdPartyAnalyticInvalid < StandardError
  end

  def self.save_third_party_analytics(analytics_params, seller)
    existing_analytics = seller.third_party_analytics.alive
    keep_analytics = []

    if analytics_params.empty?
      existing_analytics.each(&:mark_deleted)
      return []
    end

    product_hash = Hash.new { |hash, key| hash[key] = {} }
    analytics_params.each do |third_party_analytic|
      product = product_from_permalink(third_party_analytic[:product])
      raise ThirdPartyAnalyticInvalid, "Only one analytics block is allowed per product. Please consolidate your tracking segments by pasting them into in a single block." if product_hash[third_party_analytic[:location]][product.try(:id)]

      product_hash[third_party_analytic[:location]][product.try(:id)] = true
    end

    analytics_params.each do |third_party_analytic|
      product = product_from_permalink(third_party_analytic[:product])

      if third_party_analytic[:id].present?
        analytics = seller.third_party_analytics.alive.find_by_external_id(third_party_analytic[:id])
        next if analytics.nil?

        analytics.link = product if analytics.link != product
        analytics.name = third_party_analytic[:name] if third_party_analytic[:name].present?
        analytics.location = third_party_analytic[:location] if third_party_analytic[:location].present?
        analytics.analytics_code = third_party_analytic[:code] if analytics.analytics_code != third_party_analytic[:code]
        analytics.save!
      else
        analytics = seller.third_party_analytics.create!(analytics_code: third_party_analytic[:code], name: third_party_analytic[:name], location: third_party_analytic[:location], link: product)
      end

      keep_analytics << analytics
    end

    (existing_analytics - keep_analytics).each(&:mark_deleted)
    keep_analytics.map(&:external_id)
  end

  def self.product_from_permalink(permalink)
    permalink == FOR_ALL_PRODUCTS ? nil : Link.find_by(unique_permalink: permalink)
  end

  def clear_related_products_cache
    user.clear_products_cache
  end
end
