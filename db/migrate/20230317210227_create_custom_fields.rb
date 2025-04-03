# frozen_string_literal: true

class CreateCustomFields < ActiveRecord::Migration[7.0]
  def change
    create_table :custom_fields do |t|
      t.string :field_type
      t.string :name
      t.boolean :required, default: false
      t.boolean :global, default: false
      t.timestamps
      t.references :seller, null: false
    end

    create_table :custom_fields_products do |t|
      t.references :custom_field, null: false
      t.references :product, null: false
      t.timestamps
    end
  end
end
