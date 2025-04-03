# frozen_string_literal: true

class RemoveUniquenessIndexFromFailedPurchases < ActiveRecord::Migration
  def up
    remove_index :failed_purchases, name: "by_link_and_stripe_fingerprint"
  end

  def down
    add_index :failed_purchases, [:link_id, :stripe_fingerprint], unique: true, name: "by_link_and_stripe_fingerprint"
  end
end
