# frozen_string_literal: true

class AddFlagsToRefunds < ActiveRecord::Migration[6.1]
  def change
    add_column :refunds, :flags, :bigint, default: 0, null: false
  end
end
