# frozen_string_literal: true

class CreateProductInstallmentPlans < ActiveRecord::Migration[7.1]
  def change
    create_table :product_installment_plans do |t|
      t.references :link, null: false
      t.integer :number_of_installments, null: false
      t.string :recurrence, null: false

      t.timestamps
    end
  end
end
