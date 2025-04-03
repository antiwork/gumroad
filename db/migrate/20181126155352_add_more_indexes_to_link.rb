# frozen_string_literal: true

class AddMoreIndexesToLink < ActiveRecord::Migration
  def change
    add_index :links, :banned_at
    add_index :links, :deleted_at
  end
end
