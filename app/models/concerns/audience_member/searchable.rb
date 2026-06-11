# frozen_string_literal: true

module AudienceMember::Searchable
  extend ActiveSupport::Concern

  PURCHASE_DETAIL_KEYS = %w[id product_id variant_ids price_cents created_at country].freeze
  AFFILIATE_DETAIL_KEYS = %w[id product_id created_at].freeze

  # Audience members churn on every purchase and follow across all sellers, so only
  # sellers being rolled out enqueue indexing jobs. The index_audience_members flag
  # turns on syncing ahead of the audience_count_from_elasticsearch read flag: backfill
  # and verify the data while counts still come from SQL, then flip the read flag on a
  # complete index. The read flag also implies syncing so a mis-ordered rollout serves
  # an index that is merely incomplete, never one that silently rots.
  module GatedAsyncIndexing
    private
      def send_to_elasticsearch(action)
        return unless Feature.active?(:index_audience_members, seller) || Feature.active?(:audience_count_from_elasticsearch, seller)
        super
      end
  end

  included do
    include Elasticsearch::Model
    include SearchIndexModelCommon
    include ElasticsearchModelAsyncCallbacks
    prepend GatedAsyncIndexing

    index_name "audience_members"

    settings number_of_shards: 1, number_of_replicas: 0, index: {
      mapping: { nested_objects: { limit: 30_000 } }
    }

    mapping dynamic: :strict do
      indexes :seller_id, type: :long
      indexes :email, type: :keyword
      indexes :customer, type: :boolean
      indexes :follower, type: :boolean
      indexes :affiliate, type: :boolean
      indexes :min_paid_cents, type: :long
      indexes :max_paid_cents, type: :long
      indexes :min_created_at, type: :date
      indexes :max_created_at, type: :date
      indexes :min_purchase_created_at, type: :date
      indexes :max_purchase_created_at, type: :date
      indexes :follower_id, type: :long
      indexes :follower_created_at, type: :date
      indexes :min_affiliate_created_at, type: :date
      indexes :max_affiliate_created_at, type: :date
      indexes :purchases, type: :nested do
        indexes :id, type: :long
        indexes :product_id, type: :long
        indexes :variant_ids, type: :long
        indexes :price_cents, type: :long
        indexes :created_at, type: :date
        indexes :country, type: :keyword
      end
      indexes :affiliates, type: :nested do
        indexes :id, type: :long
        indexes :product_id, type: :long
        indexes :created_at, type: :date
      end
    end

    ATTRIBUTE_TO_SEARCH_FIELDS = {
      "seller_id" => "seller_id",
      "email" => "email",
      "customer" => "customer",
      "follower" => "follower",
      "affiliate" => "affiliate",
      "min_paid_cents" => "min_paid_cents",
      "max_paid_cents" => "max_paid_cents",
      "min_created_at" => "min_created_at",
      "max_created_at" => "max_created_at",
      "min_purchase_created_at" => "min_purchase_created_at",
      "max_purchase_created_at" => "max_purchase_created_at",
      "follower_created_at" => "follower_created_at",
      "min_affiliate_created_at" => "min_affiliate_created_at",
      "max_affiliate_created_at" => "max_affiliate_created_at",
      "details" => %w[purchases follower_id affiliates],
    }.freeze

    def search_field_value(field_name)
      details_hash = details || {}
      case field_name
      when "purchases"
        Array.wrap(details_hash["purchases"]).map { _1.slice(*PURCHASE_DETAIL_KEYS) }
      when "affiliates"
        Array.wrap(details_hash["affiliates"]).map { _1.slice(*AFFILIATE_DETAIL_KEYS) }
      when "follower_id"
        details_hash.dig("follower", "id")
      else
        attributes[field_name]
      end.as_json
    end
  end

  class_methods do
    def filter_count(seller_id:, params: {}, limit: nil)
      options = {
        index: index_name,
        body: { query: filter_query(seller_id:, params:) },
      }
      options[:terminate_after] = limit if limit
      EsClient.count(options)["count"]
    end

    # Total audience size from the same engine that serves the seller's filtered
    # counts: numbers displayed side by side must come from one snapshot, or the
    # engines' different sync latencies can show a filtered count above the total.
    def count_for_seller(seller)
      if Feature.active?(:audience_count_from_elasticsearch, seller)
        filter_count(seller_id: seller.id)
      else
        seller.audience_members.count
      end
    end

    # Builds an Elasticsearch query equivalent to the SQL built by AudienceMember.filter,
    # so that counts computed here always match the recipients selected by the blast jobs.
    def filter_query(seller_id:, params: {})
      params = normalize_filter_params(params)

      filter = [{ term: { seller_id: } }]
      must_not = []

      filter << { term: { params[:type] => true } } if params[:type]

      if params[:bought_product_ids] || params[:bought_variant_ids]
        filter << { nested: { path: "purchases", query: bought_products_or_variants_query(params) } }
      end

      if params[:not_bought_product_ids]
        must_not << { nested: { path: "purchases", query: { terms: { "purchases.product_id" => params[:not_bought_product_ids] } } } }
      end

      if params[:not_bought_variant_ids]
        must_not << { nested: { path: "purchases", query: { terms: { "purchases.variant_ids" => params[:not_bought_variant_ids] } } } }
      end

      filter << { range: { max_paid_cents: { gt: params[:paid_more_than_cents] } } } if params[:paid_more_than_cents]
      filter << { range: { min_paid_cents: { lt: params[:paid_less_than_cents] } } } if params[:paid_less_than_cents]

      if params[:created_after] || params[:created_before]
        min_created_at_field, max_created_at_field = \
          case params[:type]
          when "customer" then [:min_purchase_created_at, :max_purchase_created_at]
          when "follower" then [:follower_created_at, :follower_created_at]
          when "affiliate" then [:min_affiliate_created_at, :max_affiliate_created_at]
          else [:min_created_at, :max_created_at]
          end
        filter << { range: { max_created_at_field => { gt: params[:created_after] } } } if params[:created_after]
        filter << { range: { min_created_at_field => { lt: params[:created_before] } } } if params[:created_before]
      end

      if params[:bought_from]
        filter << { nested: { path: "purchases", query: { term: { "purchases.country" => params[:bought_from] } } } }
      end

      if params[:affiliate_product_ids]
        filter << { nested: { path: "affiliates", query: { terms: { "affiliates.product_id" => params[:affiliate_product_ids] } } } }
      end

      single_record_clause = filter_single_record_clause(params)
      filter << single_record_clause if single_record_clause

      query = { bool: { filter: } }
      query[:bool][:must_not] = must_not if must_not.any?
      query
    end

    private
      # Mirrors the JSON_TABLE subquery in AudienceMember.filter: when filters are combined,
      # they must all match within a single purchase / follower / affiliate record of the member,
      # not across different records.
      def filter_single_record_clause(params)
        single_record_filtering = (
          (params[:bought_product_ids] || params[:bought_variant_ids] || params[:affiliate_product_ids]) \
          && (params[:paid_more_than_cents] || params[:paid_less_than_cents] || params[:created_after] || params[:created_before] || params[:bought_from]))
        single_record_filtering ||= (params[:paid_more_than_cents] && params[:paid_less_than_cents])
        single_record_filtering ||= (params[:created_after] && params[:created_before])
        return nil unless single_record_filtering

        has_purchase_conditions = params.values_at(:bought_product_ids, :bought_variant_ids, :paid_more_than_cents, :paid_less_than_cents, :bought_from).any?
        has_affiliate_conditions = params[:affiliate_product_ids].present?
        has_date_conditions = params[:created_after].present? || params[:created_before].present?
        date_fields = single_record_date_fields(params)

        should = []

        if !has_affiliate_conditions && (!has_date_conditions || date_fields.include?("purchase_created_at"))
          conditions = []
          conditions << bought_products_or_variants_query(params) if params[:bought_product_ids] || params[:bought_variant_ids]
          conditions << { range: { "purchases.price_cents" => { gt: params[:paid_more_than_cents] } } } if params[:paid_more_than_cents]
          conditions << { range: { "purchases.price_cents" => { lt: params[:paid_less_than_cents] } } } if params[:paid_less_than_cents]
          conditions << { term: { "purchases.country" => params[:bought_from] } } if params[:bought_from]
          conditions << { range: { "purchases.created_at" => { gt: params[:created_after] } } } if params[:created_after]
          conditions << { range: { "purchases.created_at" => { lt: params[:created_before] } } } if params[:created_before]
          should << { nested: { path: "purchases", query: { bool: { filter: conditions } } } } if conditions.any?
        end

        if !has_purchase_conditions && !has_affiliate_conditions && has_date_conditions && date_fields.include?("follower_created_at")
          # The follower_id guard mirrors SQL's JSON_TABLE over the details JSON: rows whose
          # details were cleared outside callbacks (GDPR erasure) produce no JSON records there,
          # even when the denormalized follower_created_at column is still set.
          conditions = [{ exists: { field: "follower_id" } }]
          conditions << { range: { follower_created_at: { gt: params[:created_after] } } } if params[:created_after]
          conditions << { range: { follower_created_at: { lt: params[:created_before] } } } if params[:created_before]
          should << { bool: { filter: conditions } }
        end

        if !has_purchase_conditions && (!has_date_conditions || date_fields.include?("affiliate_created_at")) && (has_affiliate_conditions || has_date_conditions)
          conditions = []
          conditions << { terms: { "affiliates.product_id" => params[:affiliate_product_ids] } } if params[:affiliate_product_ids]
          conditions << { range: { "affiliates.created_at" => { gt: params[:created_after] } } } if params[:created_after]
          conditions << { range: { "affiliates.created_at" => { lt: params[:created_before] } } } if params[:created_before]
          should << { nested: { path: "affiliates", query: { bool: { filter: conditions } } } } if conditions.any?
        end

        return { match_none: {} } if should.empty?

        { bool: { should:, minimum_should_match: 1 } }
      end

      def single_record_date_fields(params)
        if params[:type] == "customer"
          %w[purchase_created_at]
        elsif params[:type] == "follower"
          if params[:bought_product_ids] || params[:bought_variant_ids]
            %w[follower_created_at purchase_created_at]
          else
            %w[follower_created_at]
          end
        elsif params[:type] == "affiliate"
          %w[affiliate_created_at]
        else
          %w[purchase_created_at follower_created_at affiliate_created_at]
        end
      end

      def bought_products_or_variants_query(params)
        bought = []
        bought << { terms: { "purchases.product_id" => params[:bought_product_ids] } } if params[:bought_product_ids]
        bought << { terms: { "purchases.variant_ids" => params[:bought_variant_ids] } } if params[:bought_variant_ids]
        { bool: { should: bought, minimum_should_match: 1 } }
      end
  end
end
