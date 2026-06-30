# frozen_string_literal: true

class CreatePurchasePaymentFlows < ActiveRecord::Migration[7.1]
  def change
    create_table :purchase_payment_flows do |t|
      t.references :purchase, index: { unique: true }, null: false
      t.string :payment_details_source, null: false, index: true
      t.string :payment_details_transport, null: false
      t.string :stripe_payment_method_type, null: false

      t.timestamps
    end
  end
end
