# frozen_string_literal: true

class CreateChargebackRingSignals < ActiveRecord::Migration[7.1]
  def change
    create_table :chargeback_ring_signals do |t|
      t.bigint :seller_id, null: false
      t.bigint :purchase_id, null: false
      t.string :decision, null: false
      t.integer :paid_sales
      t.string :dominant_card_country
      t.decimal :dominant_share_pct, precision: 5, scale: 2
      t.decimal :hosting_share_pct, precision: 5, scale: 2
      t.integer :distinct_browsers
      t.string :matched_cidr

      t.timestamps

      t.index [:seller_id, :created_at]
      t.index [:purchase_id]
      t.index [:decision, :created_at]
    end
  end
end
