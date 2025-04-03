# frozen_string_literal: true

class AddFlagsToPurchaseCustomFields < ActiveRecord::Migration[7.1]
  def change
    add_column :purchase_custom_fields, :flags, :bigint, default: 0, null: false
  end
end
