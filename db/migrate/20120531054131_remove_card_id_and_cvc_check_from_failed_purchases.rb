# frozen_string_literal: true

class RemoveCardIdAndCvcCheckFromFailedPurchases < ActiveRecord::Migration[4.2]
  def up
    remove_column :failed_purchases, :stripe_card_id
    remove_column :failed_purchases, :cvc_check
  end

  def down
    add_column :failed_purchases, :stripe_card_id, :string
    add_column :failed_purchases, :cvc_check, :boolean
  end
end
