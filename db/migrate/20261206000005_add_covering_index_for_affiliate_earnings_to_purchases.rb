# frozen_string_literal: true

class AddCoveringIndexForAffiliateEarningsToPurchases < ActiveRecord::Migration[7.1]
  disable_ddl_transaction!

  def change
    # The affiliated products dashboard (Products::AffiliatedController#index)
    # shows the global affiliate's lifetime earnings via
    # Affiliate#total_cents_earned:
    #   purchases.paid.not_chargedback_or_chargedback_reversed.sum(:affiliate_credit_cents)
    # which filters on purchase_state = 'successful', price_cents > 0,
    # stripe_refunded NULL/0, and the chargeback_date/chargeback-reversed-flag
    # predicate, then sums affiliate_credit_cents.
    #
    # The only usable index today is (affiliate_id, created_at), so MySQL has
    # to fetch every one of the affiliate's purchase rows from the clustered
    # index just to evaluate those predicates and read affiliate_credit_cents.
    # For affiliates with long sales histories that scan took ~700ms per page
    # view (Sentry transaction sample on antiwork/gumroad#6020, span
    # breakdown item 3). #6121 put a 5-minute cache in front of the sum; this
    # index makes the cache-miss recomputation itself cheap.
    #
    # The composite index covers the query exactly: equality on affiliate_id,
    # then every filtered column plus the summed affiliate_credit_cents come
    # straight out of the index with no row lookups.
    add_index :purchases,
              [:affiliate_id,
               :purchase_state,
               :price_cents,
               :stripe_refunded,
               :chargeback_date,
               :flags,
               :affiliate_credit_cents],
              name: "idx_purchases_on_affiliate_earnings_sum"
  end
end
