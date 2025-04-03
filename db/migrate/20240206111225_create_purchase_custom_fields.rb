# frozen_string_literal: true

class CreatePurchaseCustomFields < ActiveRecord::Migration[7.0]
  def change
    create_table :purchase_custom_fields do |t|
      t.belongs_to :purchase, null: false
      t.string :field_type, null: false
      t.string :name, null: false
      t.text :value

      t.timestamps
    end
  end
end
