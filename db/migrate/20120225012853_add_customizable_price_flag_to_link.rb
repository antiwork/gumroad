# frozen_string_literal: true

class AddCustomizablePriceFlagToLink < ActiveRecord::Migration
  def change
    add_column :links, :customizable_price, :boolean
  end
end
