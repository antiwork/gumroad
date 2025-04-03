# frozen_string_literal: true

class ChangeLinkSizeToBigint < ActiveRecord::Migration
  def up
    change_column :links, :size, :integer, limit: 8
  end

  def down
    change_column :links, :size, :integer, limit: 4
  end
end
