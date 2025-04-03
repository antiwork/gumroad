# frozen_string_literal: true

class ChangeSizeToBigintInProductFiles < ActiveRecord::Migration
  def up
    change_column :product_files, :size, :bigint
  end

  def down
    change_column :product_files, :size, :int
  end
end
