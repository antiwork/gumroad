# frozen_string_literal: true

class AddIndexToInstallments < ActiveRecord::Migration[4.2]
  def change
    add_index :installments, :created_at
  end
end
