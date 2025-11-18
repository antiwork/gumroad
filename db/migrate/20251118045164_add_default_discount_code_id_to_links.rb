# frozen_string_literal: true

class AddDefaultDiscountCodeIdToLinks < ActiveRecord::Migration[7.1]
  def change
    add_column :links, :default_discount_code_id, :integer, null: true, default: nil
  end
end
