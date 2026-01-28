# frozen_string_literal: true

class AddCustomerCountToInstallments < ActiveRecord::Migration[4.2]
  def change
    add_column :installments, :customer_count, :integer
  end
end
