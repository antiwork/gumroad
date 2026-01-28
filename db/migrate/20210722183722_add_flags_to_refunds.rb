# frozen_string_literal: true

class AddFlagsToRefunds < ActiveRecord::Migration[4.2]
  def change
    add_column :refunds, :flags, :bigint, default: 0, null: false
  end
end
