# frozen_string_literal: true

class AddExternalMappingIdToLinks < ActiveRecord::Migration
  def change
    add_column :links, :external_mapping_id, :string
  end
end
