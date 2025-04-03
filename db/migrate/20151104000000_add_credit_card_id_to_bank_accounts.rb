# frozen_string_literal: true

class AddCreditCardIdToBankAccounts < ActiveRecord::Migration
  def change
    add_column :bank_accounts, :credit_card_id, :integer
  end
end
