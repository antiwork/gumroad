# frozen_string_literal: true

class AddDescriptionToProductFiles < ActiveRecord::Migration[4.2]
  def up
    add_column :product_files, :description, :text
  end

  def down
    remove_column :product_files, :description
  end
end
