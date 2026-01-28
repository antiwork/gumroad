# frozen_string_literal: true

class AddIndexToStripeFingerPrint < ActiveRecord::Migration[4.2]
  def up
    add_index :credit_cards, :stripe_fingerprint
  end

  def down
    remove_index :credit_cards, :stripe_fingerprint
  end
end
