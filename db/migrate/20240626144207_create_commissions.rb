# frozen_string_literal: true

class CreateCommissions < ActiveRecord::Migration[7.1]
  def change
    create_table :commissions do |t|
      t.string :status
      t.references :deposit_purchase
      t.references :completion_purchase

      t.timestamps
    end
  end
end
