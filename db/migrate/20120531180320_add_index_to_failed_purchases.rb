# frozen_string_literal: true

class AddIndexToFailedPurchases < ActiveRecord::Migration
  def change
    # Composite Key to enforce uniqueness and speed up searches.
    add_index :failed_purchases, [:link_id, :stripe_fingerprint], unique: true, name: "by_link_and_stripe_fingerprint"
    add_index :failed_purchases, :link_id
    add_index :failed_purchases, :stripe_fingerprint
  end
end
