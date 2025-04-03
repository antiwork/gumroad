# frozen_string_literal: true

class AddPaypalEmailToPayments < ActiveRecord::Migration
  def up
    add_column :payments, :payment_address, :string
  end
end
