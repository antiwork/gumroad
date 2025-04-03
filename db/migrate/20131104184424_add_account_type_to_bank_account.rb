# frozen_string_literal: true

class AddAccountTypeToBankAccount < ActiveRecord::Migration
  def change
    add_column :bank_accounts, :account_type, :string
  end
end
