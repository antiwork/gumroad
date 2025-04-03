# frozen_string_literal: true

class CreatePaymentOptions < ActiveRecord::Migration
  def change
    create_table :payment_options, options: "DEFAULT CHARACTER SET=utf8 COLLATE=utf8_unicode_ci" do |t|
      t.references :subscription
      t.references :price

      t.timestamps
      t.datetime :deleted_at
      t.integer :flags, default: 0, null: false
    end

    add_index :payment_options, :subscription_id
    add_index :payment_options, :price_id
  end
end
