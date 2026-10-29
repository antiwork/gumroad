# frozen_string_literal: true

class CreateSellerPlanOffers < ActiveRecord::Migration[8.1]
  def change
    create_table :seller_plan_offers do |t|
      t.bigint :user_id, null: false
      t.bigint :link_id
      t.string :arm, null: false
      t.integer :price_cents, null: false
      t.string :status, null: false, default: "offered"
      t.string :stripe_checkout_session_id
      t.string :stripe_customer_id
      t.string :stripe_subscription_id
      t.datetime :offered_at, null: false
      t.datetime :activated_at
      t.datetime :canceled_at
      t.timestamps

      t.index :user_id, unique: true
      t.index :stripe_subscription_id, unique: true
    end
  end
end
