# frozen_string_literal: true

class CreateAffiliateRequests < ActiveRecord::Migration[6.1]
  def change
    create_table :affiliate_requests do |t|
      t.references :seller, type: :bigint, null: false, index: true
      t.string :name, null: false, limit: 100
      t.string :email, null: false
      t.text :promotion_text, size: :medium, null: false
      t.string :locale, null: false, default: "en"
      t.string :state
      t.datetime :state_transitioned_at
      t.timestamps
    end
  end
end
