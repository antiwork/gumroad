# frozen_string_literal: true

class PriceCheckerService
  class TimeoutError < StandardError; end

  CACHE_TTL = 1.hour
  CACHE_VERSION = "v3"
  MIN_MATCHES = 5
  TARGET_BIN_COUNT = 12
  MAX_PRICE_CENTS = 10_000_000
  ES_QUERY_TIMEOUT_MS = 2_000
  ES_HARD_TIMEOUT_S = 2.5
  NICE_INTERVALS_CENTS = [
    100, 250, 500, 1_000, 2_500, 5_000, 10_000, 25_000, 50_000,
    100_000, 250_000, 500_000, 1_000_000, 2_500_000
  ].freeze

  def self.call(product:, overrides: {}, force_refresh: false)
    new(product:, overrides:, force_refresh:).call
  end

  def initialize(product:, overrides: {}, force_refresh: false)
    @product = product
    @overrides = overrides
    @force_refresh = force_refresh
  end

  def call
    Rails.cache.fetch(cache_key, expires_in: CACHE_TTL, force: @force_refresh) do
      Timeout.timeout(ES_HARD_TIMEOUT_S) { compute }
    end
  rescue Timeout::Error
    raise TimeoutError
  end

  private
    attr_reader :product

    def effective_name
      @overrides.fetch(:name, product.name)
    end

    def effective_description
      @overrides.fetch(:description, product.description)
    end

    def effective_taxonomy_id
      @overrides.fetch(:taxonomy_id, product.taxonomy_id)
    end

    def effective_native_type
      @overrides.fetch(:native_type, product.native_type)
    end

    def effective_currency
      @overrides.fetch(:currency_code, product.price_currency_type)
    end

    def effective_taxonomy
      return product.taxonomy unless @overrides.key?(:taxonomy_id)
      effective_taxonomy_id ? Taxonomy.find_by(id: effective_taxonomy_id) : nil
    end

    def compute
      if effective_taxonomy_id.present?
        result = run_distribution(include_taxonomy: true)
        return decorate(result, tier: "with_taxonomy") if result[:match_count] >= MIN_MATCHES
      end

      result = run_distribution(include_taxonomy: false)
      return decorate(result, tier: "broadened") if result[:match_count] >= MIN_MATCHES

      {
        status: "insufficient_data",
        tier: "insufficient",
        match_count: result[:match_count],
        taxonomy_label: nil,
        currency_code: effective_currency,
        current_price_cents: product.price_cents,
        summary: nil,
        histogram: nil,
        computed_at: Time.current.iso8601,
      }
    end

    def run_distribution(include_taxonomy:)
      percentiles_response = run_search(percentiles_body(include_taxonomy:))
      match_count = percentiles_response.results.total
      return { match_count:, percentiles: nil, histogram: nil, mean: nil } if match_count < MIN_MATCHES

      pcts = percentiles_response.aggregations.dig("price_pcts", "values") || {}
      p5 = pcts["5.0"]
      p25 = pcts["25.0"]
      p50 = pcts["50.0"]
      p75 = pcts["75.0"]
      p95 = pcts["95.0"]
      mean = percentiles_response.aggregations.dig("price_mean", "value")

      return { match_count: 0, percentiles: nil, histogram: nil, mean: nil } if [p5, p25, p50, p75, p95].any?(&:nil?)

      interval = nice_interval(p5, p95)
      histogram_response = run_search(histogram_body(include_taxonomy:, interval:, p5:, p95:))
      buckets = histogram_response.aggregations.dig("price_clipped", "price_histogram", "buckets") || []

      bins = buckets.map do |b|
        from = b["key"].to_i
        {
          from_cents: from,
          to_cents: from + interval,
          count: b["doc_count"].to_i,
        }
      end

      {
        match_count:,
        percentiles: { p5:, p25:, p50:, p75:, p95: },
        histogram: { interval_cents: interval, bins: },
        mean:,
      }
    end

    def decorate(result, tier:)
      generic_taxonomy = effective_taxonomy&.slug == "other"
      {
        status: "ok",
        tier:,
        match_count: result[:match_count],
        taxonomy_label: tier == "with_taxonomy" && !generic_taxonomy ? taxonomy_label_for(effective_taxonomy) : nil,
        currency_code: effective_currency,
        current_price_cents: product.price_cents,
        summary: {
          median_cents: result[:percentiles][:p50].to_i,
          p25_cents: result[:percentiles][:p25].to_i,
          p75_cents: result[:percentiles][:p75].to_i,
          mean_cents: result[:mean].to_i,
        },
        histogram: result[:histogram],
        computed_at: Time.current.iso8601,
      }
    end

    def run_search(body)
      response = Link.search(body)
      raise TimeoutError if response.response.dig("timed_out")
      response
    end

    def percentiles_body(include_taxonomy:)
      {
        size: 0,
        timeout: "#{ES_QUERY_TIMEOUT_MS}ms",
        track_total_hits: true,
        query: base_query(include_taxonomy:),
        aggs: {
          price_pcts: { percentiles: { field: "price_cents", percents: [5, 25, 50, 75, 95] } },
          price_mean: { avg: { field: "price_cents" } },
        },
      }
    end

    def histogram_body(include_taxonomy:, interval:, p5:, p95:)
      min_bound = (p5 / interval).floor * interval
      max_bound = (p95 / interval).ceil * interval

      {
        size: 0,
        timeout: "#{ES_QUERY_TIMEOUT_MS}ms",
        track_total_hits: true,
        query: base_query(include_taxonomy:),
        aggs: {
          price_clipped: {
            filter: {
              range: { price_cents: { gte: min_bound, lte: max_bound } },
            },
            aggs: {
              price_histogram: {
                histogram: {
                  field: "price_cents",
                  interval:,
                  min_doc_count: 0,
                  extended_bounds: { min: min_bound, max: max_bound },
                },
              },
            },
          },
        },
      }
    end

    def base_query(include_taxonomy:)
      must_clauses = []
      if relevance_query.present?
        must_clauses << {
          multi_match: {
            query: relevance_query,
            fields: ["name^3", "description"],
            operator: "or",
            minimum_should_match: "30%",
          },
        }
      end

      filter_clauses = [
        { term: { is_alive: true } },
        { term: { is_recommendable: true } },
        { term: { is_subscription: product.is_recurring_billing } },
        { term: { is_bundle: false } },
        { term: { customizable_price: false } },
        { term: { native_type: effective_native_type } },
        { term: { price_currency_type: effective_currency } },
        { range: { price_cents: { gt: 0, lte: MAX_PRICE_CENTS } } },
      ]
      if include_taxonomy && effective_taxonomy_id
        filter_clauses << { terms: { taxonomy_id: taxonomy_descendant_ids } }
      end

      bool = {
        filter: filter_clauses,
        must_not: [
          { term: { user_id: product.user_id } },
          { term: { _id: product.id } },
        ],
      }
      bool[:must] = must_clauses if must_clauses.any?
      { bool: }
    end

    def relevance_query
      @relevance_query ||= [effective_name.to_s, effective_description.to_s.first(1_000)]
        .map { |s| ActionController::Base.helpers.strip_tags(s).strip }
        .reject(&:blank?)
        .join(" ")
        .presence
    end

    def taxonomy_descendant_ids
      @taxonomy_descendant_ids ||= Taxonomy.find(effective_taxonomy_id).self_and_descendants.pluck(:id)
    end

    def taxonomy_label_for(taxonomy)
      return nil if taxonomy.nil?
      Discover::TaxonomyPresenter::TAXONOMY_LABELS[taxonomy.slug] || taxonomy.slug.humanize
    end

    def nice_interval(p5, p95)
      range = [p95 - p5, 1].max
      target = range.to_f / TARGET_BIN_COUNT
      NICE_INTERVALS_CENTS.find { |i| i >= target } || NICE_INTERVALS_CENTS.last
    end

    def cache_key
      fingerprint = Digest::MD5.hexdigest(
        [
          effective_name,
          Digest::MD5.hexdigest(effective_description.to_s.first(1_000)),
          effective_native_type,
          product.is_recurring_billing,
          effective_currency,
          effective_taxonomy_id,
        ].join("|")
      )
      "price_checker:#{CACHE_VERSION}:#{product.id}:#{fingerprint}"
    end
end
