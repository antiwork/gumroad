# frozen_string_literal: true

class AddExternalMappingIdToLinks < ActiveRecord::Migration[4.2]
  def change
    add_column :links, :external_mapping_id, :string
  end
end
