# frozen_string_literal: true

class AddPositionToBundleProducts < ActiveRecord::Migration[7.1]
  def change
    add_column :bundle_products, :position, :integer
  end
end
