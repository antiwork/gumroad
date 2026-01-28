# frozen_string_literal: true

class AddCreditCardIdToBankAccounts < ActiveRecord::Migration[4.2]
  def change
    add_column :bank_accounts, :credit_card_id, :integer
  end
end
