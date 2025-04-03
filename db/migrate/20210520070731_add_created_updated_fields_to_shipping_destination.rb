# frozen_string_literal: true

class AddCreatedUpdatedFieldsToShippingDestination < ActiveRecord::Migration[6.1]
  def change
    change_table :shipping_destinations, bulk: true do |t|
      t.datetime :created_at, precision: 6
      t.datetime :updated_at, precision: 6
    end
  end
end
