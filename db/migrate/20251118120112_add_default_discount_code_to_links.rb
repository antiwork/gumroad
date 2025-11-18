# frozen_string_literal: true

class AddDefaultDiscountCodeToLinks < ActiveRecord::Migration[7.1]
  def change
    add_column :links, :default_discount_code, :string
    add_index :links, :default_discount_code
  end
end
