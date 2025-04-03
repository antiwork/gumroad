# frozen_string_literal: true

class AddMissingAnalyticsFieldsToPurchasesIndex < ActiveRecord::Migration[7.0]
  def up
    EsClient.indices.put_mapping(
      index: Purchase.index_name,
      body: {
        properties: {
          # new fields
          ip_country: { type: "keyword" },
          ip_state: { type: "keyword" },
          referrer_domain: { type: "keyword" },
          # flattened nested fields
          affiliate_credit_id: { type: "long" },
          affiliate_credit_affiliate_user_id: { type: "long" },
          affiliate_credit_amount_cents: { type: "long" },
          affiliate_credit_amount_partially_refunded_cents: { type: "long" },
          product_id: { type: "long" },
          product_unique_permalink: { type: "keyword" },
          product_name: { type: "text", analyzer: "product_name", search_analyzer: "search_product_name" },
          product_description: { type: "text" },
          seller_id: { type: "long" },
          seller_name: { type: "text", analyzer: "full_name", search_analyzer: "search_full_name" },
          purchaser_id: { type: "long" },
          subscription_id: { type: "long" },
          subscription_cancelled_at: { type: "date" },
          subscription_deactivated_at: { type: "date" }
        }
      }
    )
  end
end
