# frozen_string_literal: true

class AddAchAccountIdToPayments < ActiveRecord::Migration[4.2]
  def change
    add_column :payments, :ach_account_id, :integer
  end
end
