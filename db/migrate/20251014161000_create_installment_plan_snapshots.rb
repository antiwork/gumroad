# frozen_string_literal: true

class CreateInstallmentPlanSnapshots < ActiveRecord::Migration[7.1]
  def change
    create_table :installment_plan_snapshots do |t|
      t.integer :payment_option_id, null: false
      t.integer :number_of_installments, null: false
      t.string :recurrence, null: false
      t.integer :total_price_cents, null: false
      t.timestamps

      t.index :payment_option_id, unique: true
      t.foreign_key :payment_options, column: :payment_option_id
    end
  end
end
