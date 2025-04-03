# frozen_string_literal: true

class AddStripeCardAttributesToCreditCards < ActiveRecord::Migration
  def change
    add_column :credit_cards, :cvc_check, :boolean
    add_column :credit_cards, :card_country, :string
    add_column :credit_cards, :stripe_card_id, :string

    rename_column :credit_cards, :stripe_id, :stripe_customer_id
  end
end
