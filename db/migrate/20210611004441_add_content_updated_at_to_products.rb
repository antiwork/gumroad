# frozen_string_literal: true

class AddContentUpdatedAtToProducts < ActiveRecord::Migration[4.2]
  def change
    add_column :links, :content_updated_at, :datetime, null: true
  end
end
