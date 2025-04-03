# frozen_string_literal: true

class CreateAffiliateCredits < ActiveRecord::Migration
  def change
    create_table :affiliate_credits do |t|
      t.references :oauth_application
      t.integer :basis_points
      t.integer :amount_cents
      t.integer :oauth_application_owner_id
      t.integer :seller_id
      t.integer :purchase_id
      t.integer :link_id
      t.integer :affiliate_credit_success_balance_id
      t.integer :affiliate_credit_chargeback_balance_id
      t.integer :affiliate_credit_refund_balance_id

      t.timestamps
    end
    add_index :affiliate_credits, :purchase_id
    add_index :affiliate_credits, :oauth_application_owner_id
    add_index :affiliate_credits, :seller_id
    add_index :affiliate_credits, :link_id
  end
end
