# frozen_string_literal: true

class AddCountryToBankAccounts < ActiveRecord::Migration
  def change
    add_column :bank_accounts, :country, :string
  end
end
