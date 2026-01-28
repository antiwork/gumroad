# frozen_string_literal: true

class AddNameToInstallments < ActiveRecord::Migration[4.2]
  def change
    add_column :installments, :name, :string
  end
end
