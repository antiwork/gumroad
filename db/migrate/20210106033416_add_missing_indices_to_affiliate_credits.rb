# frozen_string_literal: true

class AddMissingIndicesToAffiliateCredits < ActiveRecord::Migration[6.0]
  def change
    change_table :affiliate_credits do |t|
      t.index :affiliate_credit_refund_balance_id
      t.index :affiliate_credit_success_balance_id
      t.index :affiliate_credit_chargeback_balance_id, name: :idx_affiliate_credits_on_affiliate_credit_chargeback_balance_id
    end
  end
end
