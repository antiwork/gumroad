# frozen_string_literal: true

class AddNameToInstallments < ActiveRecord::Migration
  def change
    add_column :installments, :name, :string
  end
end
