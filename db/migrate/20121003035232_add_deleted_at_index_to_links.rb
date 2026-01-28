# frozen_string_literal: true

class AddDeletedAtIndexToLinks < ActiveRecord::Migration[4.2]
  def change
    add_index :links, :deleted_at
  end
end
