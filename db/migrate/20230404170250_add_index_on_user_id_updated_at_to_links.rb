# frozen_string_literal: true

class AddIndexOnUserIdUpdatedAtToLinks < ActiveRecord::Migration[4.2]
  def change
    add_index :links, [:user_id, :updated_at]
  end
end
