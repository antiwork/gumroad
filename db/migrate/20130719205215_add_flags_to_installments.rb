# frozen_string_literal: true

class AddFlagsToInstallments < ActiveRecord::Migration
  def change
    add_column :installments, :flags, :integer, default: 0, null: false
  end
end
