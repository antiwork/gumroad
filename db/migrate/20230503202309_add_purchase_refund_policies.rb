# frozen_string_literal: true

class AddPurchaseRefundPolicies < ActiveRecord::Migration[7.0]
  def change
    create_table :purchase_refund_policies do |t|
      t.references :purchase, index: true, null: false
      t.string :title, null: false
      t.text :fine_print
      t.timestamps
    end
  end
end
