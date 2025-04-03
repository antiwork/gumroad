# frozen_string_literal: true

class CreatePurchasesVariants < ActiveRecord::Migration
  def change
    create_table :purchases_variants do |t|
      t.integer :purchase_id
      t.integer :variant_id
    end
  end
end
