# frozen_string_literal: true

class AddFlagsToGifts < ActiveRecord::Migration[4.2]
  def change
    add_column :gifts, :flags, :bigint, default: 0, null: false
  end
end
