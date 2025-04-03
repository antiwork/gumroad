# frozen_string_literal: true

class AddDeletedAtToInstallmentPlans < ActiveRecord::Migration[7.1]
  def change
    change_table :product_installment_plans, bulk: true do |t|
      t.datetime :deleted_at, default: nil, null: true
      t.index :deleted_at
    end

    add_belongs_to :payment_options, :product_installment_plan, default: nil, null: true
  end
end
