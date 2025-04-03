# frozen_string_literal: true

class AddFlagsToCustomFields < ActiveRecord::Migration[7.1]
  def change
    add_column :custom_fields, :flags, :bigint, default: 0, null: false
  end
end
