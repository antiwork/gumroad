# frozen_string_literal: true

class AddIndexToStripeFingerPrint < ActiveRecord::Migration
  def up
    add_index :credit_cards, :stripe_fingerprint
  end

  def down
    remove_index :credit_cards, :stripe_fingerprint
  end
end
