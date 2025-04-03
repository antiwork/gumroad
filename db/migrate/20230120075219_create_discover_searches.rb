# frozen_string_literal: true

class CreateDiscoverSearches < ActiveRecord::Migration[7.0]
  def change
    create_table :discover_searches do |t|
      t.string :query, index: true # searched text
      t.references :taxonomy, index: false # taxonomy filtering the search
      t.references :user # logged in user
      t.string :ip_address, index: true
      t.string :browser_guid, index: true
      t.boolean :autocomplete, default: false, null: false
      t.datetime :created_at, null: false, index: true
      t.datetime :updated_at, null: false
    end
  end
end
