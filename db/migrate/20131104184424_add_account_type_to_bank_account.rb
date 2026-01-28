# frozen_string_literal: true

class AddAccountTypeToBankAccount < ActiveRecord::Migration[4.2]
  def change
    add_column :bank_accounts, :account_type, :string
  end
end
