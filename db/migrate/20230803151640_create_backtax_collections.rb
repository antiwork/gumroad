# frozen_string_literal: true

class CreateBacktaxCollections < ActiveRecord::Migration[7.0]
  def change
    create_table :backtax_collections do |t|
      t.references :user, index: true, null: false
      t.references :backtax_agreement, index: true, null: false
      t.integer "amount_cents"
      t.integer "amount_cents_usd"
      t.string "currency"
      t.string "stripe_transfer_id"
      t.timestamps
    end
  end
end
