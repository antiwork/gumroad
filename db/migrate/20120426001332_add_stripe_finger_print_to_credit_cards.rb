# frozen_string_literal: true

class AddStripeFingerPrintToCreditCards < ActiveRecord::Migration[4.2]
  def change
    add_column :credit_cards, :stripe_fingerprint, :string
  end
end
