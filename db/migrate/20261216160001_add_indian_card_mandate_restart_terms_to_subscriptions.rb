# frozen_string_literal: true

class AddIndianCardMandateRestartTermsToSubscriptions < ActiveRecord::Migration[7.1]
  def change
    change_table :subscriptions, bulk: true do |t|
      t.bigint :indian_card_mandate_restart_price_cents
      t.integer :indian_card_mandate_restart_quantity
    end
  end
end
