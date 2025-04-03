# frozen_string_literal: true

class AddCustomerCountToInstallments < ActiveRecord::Migration
  def change
    add_column :installments, :customer_count, :integer
  end
end
