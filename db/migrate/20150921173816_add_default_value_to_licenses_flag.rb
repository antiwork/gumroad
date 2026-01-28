# frozen_string_literal: true

class AddDefaultValueToLicensesFlag < ActiveRecord::Migration[4.2]
  def up
    change_column :licenses, :flags, :integer, default: 0
  end

  def down
    change_column :licenses, :flags, :integer, default: nil
  end
end
