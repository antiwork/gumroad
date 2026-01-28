# frozen_string_literal: true

class AddCountryToBankAccounts < ActiveRecord::Migration[4.2]
  def change
    add_column :bank_accounts, :country, :string
  end
end
