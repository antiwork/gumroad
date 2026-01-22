# frozen_string_literal: true

class CreateUserTaxForms < ActiveRecord::Migration[7.1]
  def change
    create_table :user_tax_forms do |t|
      t.references :user, null: false, index: true
      t.integer :tax_year, null: false
      t.string :tax_form_type, null: false
      t.text :json_data
      t.timestamps

      t.index [:user_id, :tax_year, :tax_form_type], unique: true
    end
  end
end
