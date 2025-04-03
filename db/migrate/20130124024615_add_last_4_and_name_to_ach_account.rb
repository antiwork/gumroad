# frozen_string_literal: true

class AddLast4AndNameToAchAccount < ActiveRecord::Migration
  def change
    add_column :ach_accounts, :account_number_last_four, :string
    add_column :ach_accounts, :account_holder_full_name, :string
    add_column :ach_accounts, :deleted_at, :datetime
  end
end
