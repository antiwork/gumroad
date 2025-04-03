# frozen_string_literal: true

class AddFlagsToLinks < ActiveRecord::Migration
  def change
    add_column :links, :flags, :integer, default: 0, null: false
  end
end
