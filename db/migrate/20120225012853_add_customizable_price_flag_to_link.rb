# frozen_string_literal: true

class AddCustomizablePriceFlagToLink < ActiveRecord::Migration[4.2]
  def change
    add_column :links, :customizable_price, :boolean
  end
end
