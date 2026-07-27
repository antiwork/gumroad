# frozen_string_literal: true

class AddCoveringIndexForCreditSumsToAffiliateCredits < ActiveRecord::Migration[7.1]
  disable_ddl_transaction!

  def change
    # The affiliated products dashboard (Products::AffiliatedController#index)
    # shows a "total revenue" stat computed by
    # User#affiliate_credits_total_revenue_cents: a gross
    # SUM(amount_cents) over all of the user's affiliate credits.
    #
    # The only other usable index is the single-column
    # index_affiliate_credits_on_affiliate_user_id, which stores no amount, so
    # MySQL has to fetch every one of the affiliate's credit rows from the
    # clustered index just to read amount_cents. For affiliates with long
    # earning histories that scan took 1.8s+ per page view (Sentry Slow DB
    # Query issue on this transaction; details on antiwork/gumroad#6020).
    #
    # This composite index covers that sum: affiliate_user_id leads it and
    # amount_cents is stored in it, so the whole aggregate is answered from the
    # index with no row lookups at all.
    #
    # The three balance-id columns in the middle are kept deliberately even
    # though the gross sum does not filter on them. They make the same index
    # cover the per-product Revenue column and the `paid` scope used elsewhere
    # on this page, which do filter on refund/chargeback/success balance ids —
    # so one index serves every credit aggregate this dashboard runs rather
    # than needing a second one.
    add_index :affiliate_credits,
              [:affiliate_user_id,
               :affiliate_credit_refund_balance_id,
               :affiliate_credit_chargeback_balance_id,
               :affiliate_credit_success_balance_id,
               :amount_cents],
              name: "idx_affiliate_credits_on_user_and_balances_and_amount"
  end
end
