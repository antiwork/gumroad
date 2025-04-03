# frozen_string_literal: true

class AddStripeFingerPrintToCreditCards < ActiveRecord::Migration
  def change
    add_column :credit_cards, :stripe_fingerprint, :string
  end
end
