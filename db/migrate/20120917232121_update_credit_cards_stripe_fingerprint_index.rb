# frozen_string_literal: true

class UpdateCreditCardsStripeFingerprintIndex < ActiveRecord::Migration
  def up
    remove_index :credit_cards, name: "index_credit_cards_on_stripe_fingerprint"
    add_index :credit_cards, [:stripe_fingerprint], unique: true, name: "index_credit_cards_on_stripe_fingerprint_unique"
  end

  def down
    remove_index :credit_cards, name: "index_credit_cards_on_stripe_fingerprint_unique"
    add_index :credit_cards, [:stripe_fingerprint], name: "index_credit_cards_on_stripe_fingerprint"
  end
end
