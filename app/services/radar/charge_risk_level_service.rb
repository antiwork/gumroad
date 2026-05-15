# frozen_string_literal: true

module Radar
  class ChargeRiskLevelService
    CACHE_TTL = 24.hours
    CACHE_KEY_PREFIX = "stripe_charge_risk_level"
    CACHE_NIL_SENTINEL = "__nil__"

    # Fetch the Stripe Radar risk level for a purchase's charge.
    # Returns "normal", "elevated", "highest", "not_assessed", or nil if unavailable.
    def self.fetch(purchase)
      return nil unless purchase.stripe_transaction_id.present?
      return nil unless purchase.charge_processor_id == StripeChargeProcessor.charge_processor_id

      fetch_bulk([purchase])[purchase.id]
    end

    # Bulk-fetch risk levels for multiple purchases, using cache where possible.
    # Returns a hash of { purchase_id => risk_level }.
    def self.fetch_bulk(purchases)
      stripe_purchases = purchases.select do |p|
        p.stripe_transaction_id.present? &&
          p.charge_processor_id == StripeChargeProcessor.charge_processor_id
      end

      results = {}

      # Read all from cache first, using exist? to distinguish missing from cached nil.
      # Deduplicate by stripe_transaction_id to avoid redundant Stripe calls for
      # combined/bundle charges that share the same charge ID across multiple Purchase rows.
      uncached_by_key = {}
      stripe_purchases.each do |purchase|
        cache_key = "#{CACHE_KEY_PREFIX}:#{purchase.stripe_transaction_id}"
        if Rails.cache.exist?(cache_key)
          cached = Rails.cache.read(cache_key)
          results[purchase.id] = cached == CACHE_NIL_SENTINEL ? nil : cached
        else
          uncached_by_key[cache_key] ||= purchase
        end
      end

      uncached = uncached_by_key.values

      # Preload merchant_accounts to avoid N+1 queries
      ActiveRecord::Associations::Preloader.new(records: uncached, associations: [:merchant_account]).call if uncached.any?

      # Fetch uncached from Stripe (bounded — admin views should limit this)
      fetched_by_key = {}
      uncached.each do |purchase|
        risk_level = fetch_from_stripe(purchase)
        cache_key = "#{CACHE_KEY_PREFIX}:#{purchase.stripe_transaction_id}"
        Rails.cache.write(cache_key, risk_level || CACHE_NIL_SENTINEL, expires_in: CACHE_TTL)
        fetched_by_key[cache_key] = risk_level
      end

      # Fan results back out to all purchases (including duplicates sharing a charge ID)
      stripe_purchases.each do |purchase|
        next if results.key?(purchase.id)
        cache_key = "#{CACHE_KEY_PREFIX}:#{purchase.stripe_transaction_id}"
        results[purchase.id] = fetched_by_key[cache_key]
      end

      results
    end

    private_class_method def self.fetch_from_stripe(purchase)
      charge = if purchase.merchant_account&.is_a_stripe_connect_account?
        begin
          Stripe::Charge.retrieve(
            { id: purchase.stripe_transaction_id },
            { stripe_account: purchase.merchant_account.charge_processor_merchant_id }
          )
        rescue StandardError => e
          Rails.logger.error "Radar::ChargeRiskLevelService: Falling back to Gumroad account for #{purchase.stripe_transaction_id} due to #{e.inspect}"
          Stripe::Charge.retrieve(purchase.stripe_transaction_id)
        end
      else
        Stripe::Charge.retrieve(purchase.stripe_transaction_id)
      end

      charge.outcome&.risk_level
    rescue Stripe::StripeError => e
      Rails.logger.error "Radar::ChargeRiskLevelService: Failed to fetch risk level for #{purchase.stripe_transaction_id}: #{e.message}"
      nil
    end
  end
end
