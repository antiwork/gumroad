# frozen_string_literal: true

class AddIndexToInstallments < ActiveRecord::Migration[6.1]
  def change
    add_index :installments, :created_at
  end
end
