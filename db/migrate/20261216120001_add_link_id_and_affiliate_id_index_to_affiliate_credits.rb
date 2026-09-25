# frozen_string_literal: true

class AddLinkIdAndAffiliateIdIndexToAffiliateCredits < ActiveRecord::Migration[8.1]
  def change
    # One bulk ALTER: pt-online-schema-change copies the whole table per statement.
    change_table :affiliate_credits, bulk: true do |t|
      # AffiliatedProductsPresenter joins credits on (link_id, affiliate_id) with both balance ids
      # NULL and sums amount_cents. With only the link_id index, the join read every affiliate's
      # credits for the product; this index seeks to one affiliate's credits and covers the sum.
      t.index [:link_id, :affiliate_id, :affiliate_credit_chargeback_balance_id, :affiliate_credit_refund_balance_id, :amount_cents],
              name: "idx_affiliate_credits_on_link_affiliate_balances_amount"

      # A redundant left prefix of the index above.
      t.remove_index :link_id
    end
  end
end
