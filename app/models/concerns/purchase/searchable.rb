# frozen_string_literal: true

module Purchase::Searchable
  extend ActiveSupport::Concern

  included do
    include Elasticsearch::Model
    include ElasticsearchModelAsyncCallbacks
    include SearchIndexModelCommon
    include RelatedPurchaseCallbacks

    index_name "purchases"

    settings number_of_shards: 1, number_of_replicas: 0, index: {
      analysis: {
        filter: {
          autocomplete_filter: {
            type: "edge_ngram",
            min_gram: 1,
            max_gram: 20,
            token_chars: ["letter", "digit"]
          },
          full_autocomplete_filter: {
            type: "edge_ngram",
            min_gram: 1,
            max_gram: 20
          }
        },
        analyzer: {
          full_name: {
            tokenizer: "whitespace",
            filter: ["lowercase", "autocomplete_filter"]
          },
          search_full_name: {
            tokenizer: "whitespace",
            filter: "lowercase"
          },
          email: {
            tokenizer: "whitespace",
            filter: ["lowercase", "autocomplete_filter"]
          },
          search_email: {
            tokenizer: "whitespace",
            filter: "lowercase"
          },
          product_name: {
            tokenizer: "whitespace",
            filter: ["lowercase", "full_autocomplete_filter"]
          },
          search_product_name: {
            tokenizer: "whitespace",
            filter: "lowercase"
          }
        }
      }
    }

    mapping dynamic: :strict do
      indexes :id, type: :long
      indexes :can_contact, type: :boolean
      indexes :chargeback_date, type: :date
      indexes :country_or_ip_country, type: :keyword
      indexes :created_at, type: :date
      indexes :latest_charge_date, type: :date
      indexes :email, type: :text, analyzer: :email, search_analyzer: :search_email do
        indexes :raw, type: :keyword
      end
      indexes :email_domain, type: :text, analyzer: :email, search_analyzer: :search_email
      indexes :paypal_email, type: :text, analyzer: :email, search_analyzer: :search_email do
        indexes :raw, type: :keyword
      end
      indexes :fee_cents, type: :long
      indexes :full_name, type: :text, analyzer: :full_name, search_analyzer: :search_full_name
      indexes :not_chargedback_or_chargedback_reversed, type: :boolean
      indexes :not_refunded_except_subscriptions, type: :boolean
      indexes :not_subscription_or_original_subscription_purchase, type: :boolean
      indexes :successful_authorization_or_without_preorder, type: :boolean
      indexes :price_cents, type: :long
      indexes :purchase_state, type: :keyword
      indexes :amount_refunded_cents, type: :long
      indexes :fee_refunded_cents, type: :long
      indexes :tax_refunded_cents, type: :long
      indexes :selected_flags, type: :keyword
      indexes :stripe_refunded, type: :boolean
      indexes :tax_cents, type: :long
      indexes :monthly_recurring_revenue, type: :float
      indexes :ip_country, type: :keyword
      indexes :ip_state, type: :keyword
      indexes :referrer_domain, type: :keyword
      indexes :license_serial, type: :keyword
      # one-to-many associations
      indexes :variant_ids, type: :long
      # computed associations
      indexes :product_ids_from_same_seller_purchased_by_purchaser, type: :long
      indexes :variant_ids_from_same_seller_purchased_by_purchaser, type: :long
      # one-to-one associations
      indexes :affiliate_credit_id, type: :long
      indexes :affiliate_credit_affiliate_user_id, type: :long
      indexes :affiliate_credit_amount_cents, type: :long
      indexes :affiliate_credit_fee_cents, type: :long
      indexes :affiliate_credit_amount_partially_refunded_cents, type: :long
      indexes :affiliate_credit_fee_partially_refunded_cents, type: :long
      indexes :product_id, type: :long
      indexes :product_unique_permalink, type: :keyword
      indexes :product_name, type: :text, analyzer: :product_name, search_analyzer: :search_product_name
      indexes :product_description, type: :text
      indexes :seller_id, type: :long
      indexes :seller_name, type: :text, analyzer: :full_name, search_analyzer: :search_full_name
      indexes :purchaser_id, type: :long
      indexes :subscription_id, type: :long
      indexes :subscription_cancelled_at, type: :date
      indexes :subscription_deactivated_at, type: :date
      indexes :taxonomy_id, type: :long
    end

    ATTRIBUTE_TO_SEARCH_FIELDS = {
      "id" => "id",
      "can_contact" => "can_contact",
      "chargeback_date" => %w[
        chargeback_date
        not_chargedback_or_chargedback_reversed
      ],
      "country" => "country_or_ip_country",
      "created_at" => "created_at",
      "email" => ["email", "email_domain"],
      "fee_cents" => "fee_cents",
      "flags" => %w[
        selected_flags
        not_chargedback_or_chargedback_reversed
        not_subscription_or_original_subscription_purchase
        referrer_domain
      ],
      "full_name" => "full_name",
      "ip_country" => ["country_or_ip_country", "ip_country"],
      "ip_state" => "ip_state",
      "referrer" => "referrer_domain",
      "price_cents" => "price_cents",
      "purchase_state" => %w[
        purchase_state
        latest_charge_date
        successful_authorization_or_without_preorder
      ],
      "stripe_refunded" => %w[
        stripe_refunded
        not_refunded_except_subscriptions
      ],
      "tax_cents" => "tax_cents",
      "card_visual" => "paypal_email",
      "subscription_id" => "subscription_id",
      "license_serial" => "license_serial",
    }

    def search_field_value(field_name)
      case field_name
      when "id", "can_contact", "created_at", "full_name", "price_cents",
           "chargeback_date", "purchase_state", "ip_country", "ip_state",
           "fee_cents", "tax_cents"
        attributes[field_name]
      when "email"
        email&.downcase
      when "email_domain"
        email.downcase.split("@")[1] if email.present?
      when "selected_flags"
        selected_flags.map(&:to_s)
      when "stripe_refunded"
        stripe_refunded?
      when "not_chargedback_or_chargedback_reversed"
        chargeback_date.nil? || selected_flags.include?(:chargeback_reversed)
      when "not_refunded_except_subscriptions"
        !stripe_refunded? || subscription_id?
      when "not_subscription_or_original_subscription_purchase"
        subscription_id.nil? || (selected_flags.include?(:is_original_subscription_purchase) && !selected_flags.include?(:is_archived_original_subscription_purchase))
      when "successful_authorization_or_without_preorder"
        purchase_state.in?(["preorder_authorization_successful", "preorder_concluded_successfully"]) || preorder_id.nil?
      when "country_or_ip_country"
        country_or_ip_country
      when "amount_refunded_cents"
        amount_refunded_cents
      when "fee_refunded_cents"
        fee_refunded_cents
      when "tax_refunded_cents"
        tax_refunded_cents
      when "referrer_domain"
        was_product_recommended? ? REFERRER_DOMAIN_FOR_GUMROAD_RECOMMENDED_PRODUCTS : Referrer.extract_domain(referrer)
      when /\Aaffiliate_credit_(id|affiliate_user_id|amount_cents|fee_cents|amount_partially_refunded_cents|fee_partially_refunded_cents)\z/
        affiliate_credit.public_send($LAST_MATCH_INFO[1]) if affiliate_credit.present?
      when /\Aproduct_(id|unique_permalink|name)\z/
        link.attributes[$LAST_MATCH_INFO[1]]
      when "product_description"
        link.plaintext_description
      when /\Aseller_(id|name)\z/
        seller.attributes[$LAST_MATCH_INFO[1]]
      when /\Apurchaser_(id)\z/
        purchaser.attributes[$LAST_MATCH_INFO[1]] if purchaser.present?
      when /\Asubscription_(id|cancelled_at|deactivated_at)\z/
        subscription.attributes[$LAST_MATCH_INFO[1]] if subscription.present?
      when "taxonomy_id"
        link.taxonomy_id
      when "variant_ids"
        variant_attributes.ids
      when "product_ids_from_same_seller_purchased_by_purchaser"
        seller.sales.by_email(email).select("distinct link_id").map(&:link_id)
      when "variant_ids_from_same_seller_purchased_by_purchaser"
        purchases_sql = seller.sales.by_email(email).select(:id).to_sql
        variants_sql = <<~SQL
          select distinct base_variant_id from base_variants_purchases
          where purchase_id IN (#{purchases_sql})
        SQL
        ActiveRecord::Base.connection.execute(variants_sql).to_a.flatten
      when "latest_charge_date"
        if is_original_subscription_purchase? && subscription.present?
          subscription.purchases.
            force_index(:index_purchases_on_subscription_id).
            successful.order(created_at: :desc, id: :desc).
            select(:created_at).first&.created_at
        end
      when "monthly_recurring_revenue"
        if is_original_subscription_purchase? && subscription&.last_payment_option&.price&.recurrence
          recurrence = subscription.last_payment_option.price.recurrence
          price_cents.to_f / BasePrice::Recurrence.number_of_months_in_recurrence(recurrence)
        end
      when "paypal_email"
        card_visual&.downcase if card_type == CardType::PAYPAL
      when "license_serial"
        license&.serial
      end.as_json
    end
  end

  module SubscriptionCallbacks
    extend ActiveSupport::Concern
    include TransactionalAttributeChangeTracker

    included do
      after_commit :update_purchase_index, on: :update
    end

    def update_purchase_index
      tracked_columns = %w[cancelled_at deactivated_at]
      changed_tracked_columns = attributes_committed & tracked_columns
      if changed_tracked_columns.present?
        purchases.select(:id).find_each do |purchase|
          options = {
            "record_id" => purchase.id,
            "class_name" => "Purchase",
            "fields" => changed_tracked_columns.map { |name| ["subscription_#{name}"] }.flatten
          }
          ElasticsearchIndexerWorker.perform_in(2.seconds, "update", options)
        end
      end
    end
  end

  module RelatedPurchaseCallbacks
    extend ActiveSupport::Concern

    included do
      after_commit :update_related_purchase_documents, on: [:create, :update]
      after_commit :update_same_purchaser_subscription_purchase_documents, on: [:create, :update]
    end

    private
      def update_related_purchase_documents
        successful_states = %w[successful gift_receiver_purchase_successful preorder_authorization_successful]
        # no need to update if the purchase is not successful, as the seller will never be aware of it
        return unless successful_states.include?(purchase_state)
        # no need to update if the state didn't change
        return unless previous_changes.key?(:purchase_state)
        # no need to update if the state changed but is still successful
        return if successful_states.include?(previous_changes[:purchase_state])

        query = PurchaseSearchService.new(
          seller:,
          email:,
          exclude_purchase: self
        ).query

        options = {
          "source_record_id" => id,
          "query" => query.deep_stringify_keys,
          "class_name" => "Purchase",
          "fields" => [
            "product_ids_from_same_seller_purchased_by_purchaser",
            "variant_ids_from_same_seller_purchased_by_purchaser"
          ]
        }

        ElasticsearchIndexerWorker.set(queue: "low").perform_in(rand(72.hours), "update_by_query", options)
      end

      def update_same_purchaser_subscription_purchase_documents
        should_update = successful?
        should_update &= previous_changes.key?(:purchase_state)
        should_update &= !is_original_subscription_purchase?
        should_update &= subscription.present? && subscription.original_purchase.present?
        return unless should_update

        options = {
          "record_id" => subscription.original_purchase.id,
          "class_name" => "Purchase",
          "fields" => [
            "latest_charge_date",
          ]
        }
        ElasticsearchIndexerWorker.perform_in(2.seconds, "update", options)
      end
  end

  module VariantAttributeCallbacks
    def self.variants_changed(purchase)
      options = {
        "record_id" => purchase.id,
        "class_name" => "Purchase",
        "fields" => [
          "variant_ids",
          "variant_ids_from_same_seller_purchased_by_purchaser"
        ]
      }
      ElasticsearchIndexerWorker.perform_in(2.seconds, "update", options)

      query = PurchaseSearchService.new(
        seller: purchase.seller,
        email: purchase.email,
        exclude_purchase: purchase
      ).query

      options = {
        "source_record_id" => purchase.id,
        "query" => query.deep_stringify_keys,
        "class_name" => "Purchase",
        "fields" => [
          "variant_ids_from_same_seller_purchased_by_purchaser"
        ]
      }

      ElasticsearchIndexerWorker.set(queue: "low").perform_in(rand(72.hours), "update_by_query", options)
    end
  end

  module AffiliateCreditCallbacks
    extend ActiveSupport::Concern

    included do
      after_commit :update_purchase_index, on: [:create, :update]
    end

    def update_purchase_index
      tracked_columns = %w[
        id
        affiliate_user_id
        amount_cents
        fee_cents
      ]
      changed_tracked_columns = previous_changes.keys & tracked_columns
      return if changed_tracked_columns.blank?

      options = {
        "record_id" => purchase.id,
        "class_name" => "Purchase",
        "fields" => changed_tracked_columns.map { |name| ["affiliate_credit_#{name}"] }.flatten
      }
      ElasticsearchIndexerWorker.perform_in(2.seconds, "update", options)
    end
  end

  module AffiliatePartialRefundCallbacks
    extend ActiveSupport::Concern

    included do
      after_commit :update_purchase_index, on: [:create, :update]
    end

    def update_purchase_index
      return unless previous_changes.key?("amount_cents")
      options = {
        "record_id" => purchase.id,
        "class_name" => "Purchase",
        "fields" => ["affiliate_credit_amount_partially_refunded_cents", "affiliate_credit_amount_fee_partially_refunded_cents"]
      }
      ElasticsearchIndexerWorker.perform_in(2.seconds, "update", options)
    end
  end

  module ProductCallbacks
    extend ActiveSupport::Concern

    included do
      after_commit :update_sales_taxonomy_id, on: :update
    end

    def update_sales_taxonomy_id
      return unless previous_changes.key?("taxonomy_id")
      first_sale_id = sales.pick(:id)
      return if first_sale_id.nil?

      query = PurchaseSearchService.new(product: self).query
      options = {
        "class_name" => Purchase.name,
        "fields" => ["taxonomy_id"],
        "source_record_id" => first_sale_id,
        "query" => query.deep_stringify_keys
      }
      ElasticsearchIndexerWorker.set(queue: "low").perform_in(rand(72.hours), "update_by_query", options)
    end
  end
end
