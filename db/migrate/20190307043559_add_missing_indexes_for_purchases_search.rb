# frozen_string_literal: true

class AddMissingIndexesForPurchasesSearch < ActiveRecord::Migration
  def up
    add_index :purchases, :email, length: 191, name: "index_purchases_on_email_long"
    remove_index :purchases, name: "index_purchases_on_email"

    add_index :purchases, [:seller_id, :purchase_state, :flags, :email], name: "index_purchases_on_seller_id_and_state_and_flags_and_email", length: { email: 191 }
    add_index :subscriptions, [:link_id, :flags]
    add_index :gifts, :giftee_purchase_id
  end

  def down
    add_index :purchases, :email, length: 10, name: "index_purchases_on_email"
    remove_index :purchases, name: "index_purchases_on_email_long"

    remove_index :purchases, name: "index_purchases_on_seller_id_and_state_and_flags_and_email"
    remove_index :subscriptions, [:link_id, :flags]
    remove_index :gifts, :giftee_purchase_id
  end
end
