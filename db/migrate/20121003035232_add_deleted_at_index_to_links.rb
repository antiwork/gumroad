# frozen_string_literal: true

class AddDeletedAtIndexToLinks < ActiveRecord::Migration
  def change
    add_index :links, :deleted_at
  end
end
