# frozen_string_literal: true

class AddCoveringIndexForCreditSumsToAffiliateCredits < ActiveRecord::Migration[7.1]
  disable_ddl_transaction!

  def change
    # The affiliated products dashboard (Products::AffiliatedController#index)
    # shows a "total revenue" stat computed by User#affiliate_credits_sum_total:
    # SUM(amount_cents) over the user's affiliate credits restricted to "paid"
    # ones — refund/chargeback balance ids NULL, success balance id NOT NULL.
    #
    # The only usable index today is the single-column
    # index_affiliate_credits_on_affiliate_user_id, so MySQL has to fetch every
    # one of the affiliate's credit rows from the clustered index just to check
    # the three balance-id predicates and read amount_cents. For affiliates with
    # long earning histories that scan took 1.8s+ per page view (Sentry Slow DB
    # Query issue on this transaction; details on antiwork/gumroad#6020).
    #
    # This composite index covers the query exactly: equality on
    # affiliate_user_id, the three balance-id NULL/NOT NULL checks, and
    # amount_cents all come straight out of the index with no row lookups.
    add_index :affiliate_credits,
              [:affiliate_user_id,
               :affiliate_credit_refund_balance_id,
               :affiliate_credit_chargeback_balance_id,
               :affiliate_credit_success_balance_id,
               :amount_cents],
              name: "idx_affiliate_credits_on_user_and_balances_and_amount"
  end
end
