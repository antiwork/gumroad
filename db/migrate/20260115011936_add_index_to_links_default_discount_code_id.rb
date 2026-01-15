# frozen_string_literal: true

class AddIndexToLinksDefaultDiscountCodeId < ActiveRecord::Migration[7.1]
  def change
    add_index :links, :default_discount_code_id
  end
end
