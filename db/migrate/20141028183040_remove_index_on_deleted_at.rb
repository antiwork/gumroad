# frozen_string_literal: true

class RemoveIndexOnDeletedAt < ActiveRecord::Migration
  def change
    remove_index :links, :deleted_at
  end
end
