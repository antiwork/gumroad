# frozen_string_literal: true

class AddInstallmentTypeToInstallments < ActiveRecord::Migration[4.2]
  def change
    add_column :installments, :installment_type, :string
  end
end
