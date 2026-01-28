# frozen_string_literal: true

class AddCreditCardToSubscription < ActiveRecord::Migration[4.2]
  def change
    add_column :subscriptions, :credit_card_id, :integer
  end
end
