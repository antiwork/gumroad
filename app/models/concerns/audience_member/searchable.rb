# frozen_string_literal: true

module AudienceMember::Searchable
  extend ActiveSupport::Concern

  included do
    include Elasticsearch::Model
    include ElasticsearchModelAsyncCallbacks
    include SearchIndexModelCommon

    index_name "audience_members"

    settings number_of_shards: 1, number_of_replicas: 0

    mapping dynamic: :strict do
      indexes :id, type: :long
      indexes :seller_id, type: :long
      indexes :email, type: :keyword
      indexes :customer, type: :boolean
      indexes :follower, type: :boolean
      indexes :affiliate, type: :boolean
      indexes :min_paid_cents, type: :long
      indexes :max_paid_cents, type: :long
      indexes :min_purchase_created_at, type: :date
      indexes :max_purchase_created_at, type: :date
      indexes :follower_created_at, type: :date
      indexes :min_affiliate_created_at, type: :date
      indexes :max_affiliate_created_at, type: :date
      indexes :min_created_at, type: :date
      indexes :max_created_at, type: :date
      indexes :created_at, type: :date
      indexes :updated_at, type: :date
      indexes :purchased_product_ids, type: :long
      indexes :purchased_variant_ids, type: :long
      indexes :purchase_countries, type: :keyword
      indexes :affiliate_product_ids, type: :long
      indexes :purchases, type: :nested do
        indexes :id, type: :long
        indexes :product_id, type: :long
        indexes :variant_ids, type: :long
        indexes :price_cents, type: :long
        indexes :created_at, type: :date
        indexes :country, type: :keyword
      end
      indexes :follower_details, type: :object do
        indexes :id, type: :long
        indexes :created_at, type: :date
      end
      indexes :affiliates, type: :nested do
        indexes :id, type: :long
        indexes :product_id, type: :long
        indexes :created_at, type: :date
      end
    end

    ATTRIBUTE_TO_SEARCH_FIELDS = {
      "id" => "id",
      "seller_id" => "seller_id",
      "email" => "email",
      "customer" => "customer",
      "follower" => "follower",
      "affiliate" => "affiliate",
      "min_paid_cents" => "min_paid_cents",
      "max_paid_cents" => "max_paid_cents",
      "min_purchase_created_at" => "min_purchase_created_at",
      "max_purchase_created_at" => "max_purchase_created_at",
      "follower_created_at" => "follower_created_at",
      "min_affiliate_created_at" => "min_affiliate_created_at",
      "max_affiliate_created_at" => "max_affiliate_created_at",
      "min_created_at" => "min_created_at",
      "max_created_at" => "max_created_at",
      "created_at" => "created_at",
      "updated_at" => "updated_at",
      "details" => %w[
        purchased_product_ids
        purchased_variant_ids
        purchase_countries
        affiliate_product_ids
        purchases
        follower_details
        affiliates
      ],
    }.freeze

    def search_field_value(field_name)
      case field_name
      when "id", "seller_id", "email", "customer", "follower", "affiliate",
           "min_paid_cents", "max_paid_cents", "min_purchase_created_at", "max_purchase_created_at",
           "follower_created_at", "min_affiliate_created_at", "max_affiliate_created_at",
           "min_created_at", "max_created_at", "created_at", "updated_at"
        attributes[field_name]
      when "purchased_product_ids"
        Array.wrap(details&.dig("purchases")).flat_map { |p| p["product_id"] }.compact.uniq
      when "purchased_variant_ids"
        Array.wrap(details&.dig("purchases")).flat_map { |p| Array.wrap(p["variant_ids"]) }.flatten.compact.uniq
      when "purchase_countries"
        Array.wrap(details&.dig("purchases")).map { |p| p["country"] }.compact.uniq
      when "affiliate_product_ids"
        Array.wrap(details&.dig("affiliates")).map { |a| a["product_id"] }.compact.uniq
      when "purchases"
        Array.wrap(details&.dig("purchases")).map do |p|
          {
            id: p["id"],
            product_id: p["product_id"],
            variant_ids: Array.wrap(p["variant_ids"]),
            price_cents: p["price_cents"],
            created_at: p["created_at"],
            country: p["country"],
          }.compact_blank
        end
      when "follower_details"
        details&.dig("follower").present? ? { id: details["follower"]["id"], created_at: details["follower"]["created_at"] }.compact_blank : nil
      when "affiliates"
        Array.wrap(details&.dig("affiliates")).map do |a|
          { id: a["id"], product_id: a["product_id"], created_at: a["created_at"] }.compact_blank
        end
      end.as_json
    end
  end
end
