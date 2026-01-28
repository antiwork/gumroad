# frozen_string_literal: true

class AddFlagsToCharges < ActiveRecord::Migration[4.2]
  def change
    add_column :charges, :flags, :bigint, default: 0, null: false
  end
end
