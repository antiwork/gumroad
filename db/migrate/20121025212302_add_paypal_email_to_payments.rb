# frozen_string_literal: true

class AddPaypalEmailToPayments < ActiveRecord::Migration[4.2]
  def up
    add_column :payments, :payment_address, :string
  end
end
