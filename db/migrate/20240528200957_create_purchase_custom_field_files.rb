# frozen_string_literal: true

class CreatePurchaseCustomFieldFiles < ActiveRecord::Migration[7.1]
  def change
    create_table :purchase_custom_field_files do |t|
      t.string :url
      t.references :purchase_custom_field, null: false

      t.timestamps
    end
  end
end
