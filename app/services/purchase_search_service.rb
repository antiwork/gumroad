# frozen_string_literal: true

class PurchaseSearchService
  DEFAULT_OPTIONS = {
    # There must not be any active filters by default: calling .search without any options should return all purchases.
    # Values - They can be an ActiveRecord object, an id, or an Array of both
    seller: nil,
    purchaser: nil,
    revenue_sharing_user: nil,
    product: nil,
    exclude_product: nil,
    exclude_purchasers_of_product: nil,
    variant: nil,
    exclude_variant: nil,
    exclude_purchasers_of_variant: nil,
    exclude_purchase: nil,
    any_products_or_variants: nil,
    affiliate_user: nil,
    taxonomy: nil,
    # Booleans
    exclude_non_original_subscription_purchases: false,
    exclude_deactivated_subscriptions: false,
    exclude_cancelled_or_pending_cancellation_subscriptions: false,
    exclude_refunded: false,
    exclude_refunded_except_subscriptions: false,
    exclude_unreversed_chargedback: false,
    exclude_cant_contact: false,
    exclude_giftees: false,
    exclude_gifters: false,
    exclude_non_successful_preorder_authorizations: false,
    exclude_bundle_product_purchases: false,
    exclude_commission_completion_purchases: false,
    # Ranges
    price_greater_than: nil, # Integer, compared to price_cents
    price_less_than: nil, # Integer, compared to price_cents
    created_after: nil, # Time or valid datetime string
    created_on_or_after: nil, # Time or valid datetime string
    created_before: nil, # Time or valid datetime string
    created_on_or_before: nil, # Time or valid datetime string
    # Others
    country: nil,
    email: nil,
    state: nil,
    archived: nil, # Boolean
    recommended: nil, # Boolean
    # Fulltext search
    seller_query: nil, # String
    buyer_query: nil, # String
    # Native ES params
    # Most useful defaults to have when using this service in console
    from: 0,
    size: 5,
    sort: nil, # usually: [ { created_at: :desc }, { id: :desc } ],
    _source: false,
    aggs: {},
    track_total_hits: nil,
  }

  attr_accessor :body

  def initialize(options = {})
    @options = DEFAULT_OPTIONS.merge(options)
    build_body
  end

  def process
    Purchase.search(@body)
  end

  def query = @body[:query]

  def self.search(options = {})
    new(options).process
  end

  private
    def build_body
      @body = { query: { bool: Hash.new { |hash, key| hash[key] = [] } } }
      ### Filters
      # Objects and ids
      build_body_seller
      build_body_purchaser
      build_body_product
      build_body_buyer_search
      build_body_exclude_product
      build_body_exclude_purchasers_of_product
      build_body_variant
      build_body_exclude_variant
      build_body_exclude_purchasers_of_variant
      build_body_exclude_purchase
      build_body_any_products_or_variants
      build_body_affiliate_user
      build_body_revenue_sharing_user
      build_body_taxonomy
      # Booleans
      build_body_exclude_refunded
      build_body_exclude_refunded_except_subscriptions
      build_body_exclude_unreversed_chargedback
      build_body_exclude_non_original_subscription_purchases
      build_body_exclude_not_charged_non_free_trial_purchases
      build_body_exclude_deactivated_subscriptions
      build_body_exclude_cancelled_or_pending_cancellation_subscriptions
      build_body_exclude_cant_contact
      build_body_exclude_giftees
      build_body_exclude_gifters
      build_body_exclude_non_successful_preorder_authorizations
      build_body_exclude_bundle_product_purchases
      build_body_exclude_commission_completion_purchases
      # Ranges
      build_body_price_greater_than
      build_body_price_less_than
      build_body_created_after
      build_body_created_on_or_after
      build_body_created_before
      build_body_created_on_or_before
      # Others
      build_body_country
      build_body_email
      build_body_state
      build_body_archived
      build_body_recommended
      ### Fulltext search
      build_body_fulltext_search
      build_body_native_params
    end

    def build_body_seller
      return if @options[:seller].blank?
      ids = Array.wrap(@options[:seller]).map do |seller|
        seller.is_a?(User) ? seller.id : seller
      end
      @body[:query][:bool][:filter] << { terms: { "seller_id" => ids } }
    end

    def build_body_purchaser
      return if @options[:purchaser].blank?
      ids = Array.wrap(@options[:purchaser]).map do |purchaser|
        purchaser.is_a?(User) ? purchaser.id : purchaser
      end
      @body[:query][:bool][:filter] << { terms: { "purchaser_id" => ids } }
    end

    def build_body_product
      return if @options[:product].blank?
      ids = Array.wrap(@options[:product]).map do |product|
        product.is_a?(Link) ? product.id : product
      end
      @body[:query][:bool][:filter] << { terms: { "product_id" => ids } }
    end

    def build_body_exclude_product
      Array.wrap(@options[:exclude_product]).each do |product|
        product_id = product.is_a?(Link) ? product.id : product
        @body[:query][:bool][:must_not] << { term: { "product_id" => product_id } }
      end
    end

    def build_body_exclude_purchasers_of_product
      Array.wrap(@options[:exclude_purchasers_of_product]).each do |product|
        product_id = product.is_a?(Link) ? product.id : product
        @body[:query][:bool][:must_not] << {
          term: { "product_ids_from_same_seller_purchased_by_purchaser" => product_id }
        }
      end
    end

    def build_body_variant
      return if @options[:variant].blank?
      variant_ids = Array.wrap(@options[:variant]).map do |variant|
        variant.is_a?(BaseVariant) ? variant.id : variant
      end
      @body[:query][:bool][:filter] << { terms: { "variant_ids" => variant_ids } }
    end

    def build_body_exclude_variant
      Array.wrap(@options[:exclude_variant]).each do |variant|
        variant_id = variant.is_a?(BaseVariant) ? variant.id : variant
        @body[:query][:bool][:must_not] << { term: { "variant_ids" => variant_id } }
      end
    end

    def build_body_exclude_purchasers_of_variant
      Array.wrap(@options[:exclude_purchasers_of_variant]).each do |variant|
        variant_id = variant.is_a?(BaseVariant) ? variant.id : variant
        @body[:query][:bool][:must_not] << {
          term: { "variant_ids_from_same_seller_purchased_by_purchaser" => variant_id }
        }
      end
    end

    def build_body_exclude_purchase
      Array.wrap(@options[:exclude_purchase]).each do |purchase|
        purchase_id = purchase.is_a?(Purchase) ? purchase.id : purchase
        @body[:query][:bool][:must_not] << { term: { "id" => purchase_id } }
      end
    end

    def build_body_any_products_or_variants
      return if @options[:any_products_or_variants].blank?
      should = []
      if @options[:any_products_or_variants][:products].present?
        product_ids = Array.wrap(@options[:any_products_or_variants][:products]).map do |product|
          product.is_a?(Link) ? product.id : product
        end
        should << { terms: { "product_id" => product_ids } }
      end
      if @options[:any_products_or_variants][:variants].present?
        variant_ids = Array.wrap(@options[:any_products_or_variants][:variants]).map do |variant|
          variant.is_a?(BaseVariant) ? variant.id : variant
        end
        should << { terms: { "variant_ids" => variant_ids } }
      end
      return if should.empty?
      @body[:query][:bool][:filter] << { bool: { minimum_should_match: 1, should: } }
    end

    def build_body_affiliate_user
      return if @options[:affiliate_user].blank?
      ids = Array.wrap(@options[:affiliate_user]).map do |affiliate_user|
        affiliate_user.is_a?(User) ? affiliate_user.id : affiliate_user
      end
      @body[:query][:bool][:filter] << { terms: { "affiliate_credit_affiliate_user_id" => ids } }
    end

    def build_body_revenue_sharing_user
      return if @options[:revenue_sharing_user].blank?
      ids = Array.wrap(@options[:revenue_sharing_user]).map do |user|
        user.is_a?(User) ? user.id : user
      end
      should = [
        { terms: { "affiliate_credit_affiliate_user_id" => ids } },
        { terms: { "seller_id" => ids } },
      ]
      @body[:query][:bool][:filter] << { bool: { minimum_should_match: 1, should: } }
    end

    def build_body_taxonomy
      return if @options[:taxonomy].blank?
      ids = Array.wrap(@options[:taxonomy]).map do |taxonomy|
        taxonomy.is_a?(Taxonomy) ? taxonomy.id : taxonomy
      end
      @body[:query][:bool][:filter] << { terms: { "taxonomy_id" => ids } }
    end

    def build_body_exclude_refunded
      return unless @options[:exclude_refunded]
      @body[:query][:bool][:filter] << { term: { "stripe_refunded" => false } }
    end

    def build_body_exclude_refunded_except_subscriptions
      return unless @options[:exclude_refunded_except_subscriptions]
      @body[:query][:bool][:filter] << { term: { "not_refunded_except_subscriptions" => true } }
    end

    def build_body_exclude_unreversed_chargedback
      return unless @options[:exclude_unreversed_chargedback]
      @body[:query][:bool][:filter] << { term: { "not_chargedback_or_chargedback_reversed" => true } }
    end

    def build_body_exclude_non_original_subscription_purchases
      return unless @options[:exclude_non_original_subscription_purchases]
      @body[:query][:bool][:filter] << { term: { "not_subscription_or_original_subscription_purchase" => true } }
    end

    def build_body_exclude_not_charged_non_free_trial_purchases
      return unless @options[:exclude_not_charged_non_free_trial_purchases]
      @body[:query][:bool][:must_not] << {
        bool: {
          must: [
            { term: { "purchase_state" => "not_charged" } },
            bool: { must_not: [{ term: { "selected_flags" => "is_free_trial_purchase" } }] }
          ]
        }
      }
    end

    def build_body_exclude_deactivated_subscriptions
      return unless @options[:exclude_deactivated_subscriptions]
      @body[:query][:bool][:must_not] << { exists: { field: "subscription_deactivated_at" } }
    end

    def build_body_exclude_cancelled_or_pending_cancellation_subscriptions
      return unless @options[:exclude_cancelled_or_pending_cancellation_subscriptions]
      @body[:query][:bool][:must_not] << { exists: { field: "subscription_cancelled_at" } }
    end

    def build_body_exclude_cant_contact
      return unless @options[:exclude_cant_contact]
      @body[:query][:bool][:filter] << { term: { "can_contact" => true } }
    end

    def build_body_exclude_giftees
      return unless @options[:exclude_giftees]
      @body[:query][:bool][:must_not] << { term: { "selected_flags" => "is_gift_receiver_purchase" } }
    end

    def build_body_exclude_gifters
      return unless @options[:exclude_gifters]
      @body[:query][:bool][:must_not] << { term: { "selected_flags" => "is_gift_sender_purchase" } }
    end

    def build_body_exclude_non_successful_preorder_authorizations
      return unless @options[:exclude_non_successful_preorder_authorizations]
      @body[:query][:bool][:filter] << { term: { "successful_authorization_or_without_preorder" => true } }
    end

    def build_body_exclude_bundle_product_purchases
      return unless @options[:exclude_bundle_product_purchases]
      @body[:query][:bool][:must_not] << { term: { "selected_flags" => "is_bundle_product_purchase" } }
    end

    def build_body_exclude_commission_completion_purchases
      return unless @options[:exclude_commission_completion_purchases]
      @body[:query][:bool][:must_not] << { term: { "selected_flags" => "is_commission_completion_purchase" } }
    end

    def build_body_price_greater_than
      return unless @options[:price_greater_than]
      @body[:query][:bool][:must] << { range: { "price_cents" => { gt: @options[:price_greater_than] } } }
    end

    def build_body_price_less_than
      return unless @options[:price_less_than]
      @body[:query][:bool][:must] << { range: { "price_cents" => { lt: @options[:price_less_than] } } }
    end

    def build_body_created_after
      return unless @options[:created_after]
      @body[:query][:bool][:must] << { range: { "created_at" => { gt: @options[:created_after].iso8601 } } }
    end

    def build_body_created_on_or_after
      return unless @options[:created_on_or_after]
      @body[:query][:bool][:must] << { range: { "created_at" => { gte: @options[:created_on_or_after].iso8601 } } }
    end

    def build_body_created_before
      return unless @options[:created_before]
      @body[:query][:bool][:must] << { range: { "created_at" => { lt: @options[:created_before].iso8601 } } }
    end

    def build_body_created_on_or_before
      return unless @options[:created_on_or_before]
      @body[:query][:bool][:must] << { range: { "created_at" => { lte: @options[:created_on_or_before].iso8601 } } }
    end

    def build_body_country
      return unless @options[:country]
      @body[:query][:bool][:filter] << {
        terms: {
          "country_or_ip_country" => Array.wrap(@options[:country])
        }
      }
    end

    def build_body_email
      return unless @options[:email]
      @body[:query][:bool][:filter] << { term: { "email.raw" => @options[:email].downcase } }
    end

    def build_body_state
      return unless @options[:state]
      @body[:query][:bool][:filter] << {
        terms: {
          "purchase_state" => Array.wrap(@options[:state])
        }
      }
    end

    def build_body_archived
      return if @options[:archived].nil?
      must = @options[:archived] ? :must : :must_not
      @body[:query][:bool][must] << { term: { "selected_flags" => "is_archived" } }
    end

    def build_body_recommended
      return if @options[:recommended].nil?
      must = @options[:recommended] ? :must : :must_not
      @body[:query][:bool][must] << { term: { "selected_flags" => "was_product_recommended" } }
    end

    def build_body_fulltext_search
      return if @options[:seller_query].blank?
      query_string = @options[:seller_query].strip.downcase

      shoulds = []
      all_words_query = query_string.match(/\A"(.*)"\z/).try(:[], 1)
      if all_words_query
        shoulds << {
          multi_match: {
            query: all_words_query,
            fields: ["full_name"],
            operator: "and",
          }
        }
      else
        shoulds << {
          multi_match: {
            query: query_string,
            fields: ["email", "email_domain", "full_name"]
          }
        }
        if query_string.include?("@")
          shoulds << { term: { "email.raw" => query_string } }
          shoulds << { term: { "paypal_email.raw" => query_string } }
        end
        if query_string.match?(/\A[a-f0-9]{8}-[a-f0-9]{8}-[a-f0-9]{8}-[a-f0-9]{8}\z/)
          shoulds << { term: { "license_serial" => query_string.upcase } }
        end
      end

      @body[:query][:bool][:must] << {
        bool: {
          minimum_should_match: 1,
          should: shoulds,
        }
      }
    end

    def build_body_buyer_search
      return if @options[:buyer_query].blank?
      query_string = @options[:buyer_query].strip.downcase

      body[:query][:bool][:must] << {
        multi_match: {
          query: query_string,
          fields: ["product_name", "product_description", "seller_name"]
        }
      }
    end

    def build_body_native_params
      [
        :from,
        :size,
        :sort,
        :_source,
        :aggs,
        :track_total_hits,
      ].each do |option_name|
        next if @options[option_name].nil?
        @body[option_name] = @options[option_name]
      end
    end
end
