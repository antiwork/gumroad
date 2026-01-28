# frozen_string_literal: true

class AddSplitPaymentByCentsToUsers < ActiveRecord::Migration[4.2]
  def up
    add_column :users, :split_payment_by_cents, :integer
  end

  def down
    remove_column :users, :split_payment_by_cents
  end
end
