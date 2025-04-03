# frozen_string_literal: true

class CreateRefundPolicies < ActiveRecord::Migration[7.0]
  def change
    create_table :refund_policies do |t|
      t.references :seller, index: true, null: false
      t.references :product, index: { unique: true }, null: false
      t.string :title, null: false
      t.text :fine_print
      t.timestamps
    end
  end
end
