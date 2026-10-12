# frozen_string_literal: true

class AddIndianCardMandateRestartBuyerToSubscriptions < ActiveRecord::Migration[7.1]
  def change
    add_column :subscriptions, :indian_card_mandate_restart_buyer_id, :bigint
  end
end
