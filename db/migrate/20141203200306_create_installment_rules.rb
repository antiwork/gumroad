# frozen_string_literal: true

class CreateInstallmentRules < ActiveRecord::Migration
  def change
    create_table :installment_rules do |t|
      t.integer :installment_id
      t.integer :relative_delivery_time
      t.datetime :to_be_published_at
      t.integer :version, default: 0, null: false
      t.datetime :deleted_at

      t.timestamps
    end

    add_index :installment_rules, [:installment_id], unique: true
  end
end
