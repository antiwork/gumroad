# frozen_string_literal: true

class CreateStripeApplePayDomains < ActiveRecord::Migration[6.1]
  def change
    create_table :stripe_apple_pay_domains do |t|
      t.references :user, null: false, index: true
      t.string :domain, null: false, index: { unique: true }
      t.string :stripe_id, null: false
      t.timestamps
    end
  end
end
