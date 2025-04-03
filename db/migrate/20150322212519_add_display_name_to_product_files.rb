# frozen_string_literal: true

class AddDisplayNameToProductFiles < ActiveRecord::Migration
  def change
    add_column :product_files, :display_name, :string
  end
end
