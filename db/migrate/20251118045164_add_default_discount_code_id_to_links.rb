# frozen_string_literal: true

class AddDefaultDiscountCodeIdToLinks < ActiveRecord::Migration[7.1]
  def change
    add_column :links, :default_discount_code_id, :integer, null: true, default: nil
    add_foreign_key :links, :offer_codes, column: :default_discount_code_id
    add_index :links, :default_discount_code_id
  end
end

