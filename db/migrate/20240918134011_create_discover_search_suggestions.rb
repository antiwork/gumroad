# frozen_string_literal: true

class CreateDiscoverSearchSuggestions < ActiveRecord::Migration[7.1]
  def change
    create_table :discover_search_suggestions do |t|
      t.belongs_to :discover_search
      t.datetime :deleted_at

      t.timestamps
    end
  end
end
