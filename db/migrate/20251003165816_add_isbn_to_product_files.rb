# frozen_string_literal: true

class AddIsbnToProductFiles < ActiveRecord::Migration[7.1]
  def change
    add_column :product_files, :isbn, :string
  end
end
