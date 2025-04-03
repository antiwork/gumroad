# frozen_string_literal: true

class CreateSelfServiceAffiliateProducts < ActiveRecord::Migration[6.1]
  def change
    create_table :self_service_affiliate_products do |t|
      t.references :seller, type: :bigint, null: false, index: true
      t.references :product, type: :bigint, null: false, index: { unique: true }
      t.boolean :enabled, default: false, null: false
      t.integer :affiliate_basis_points, null: false
      t.string :destination_url, limit: 2083
      t.timestamps
    end
  end
end
