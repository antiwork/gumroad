# frozen_string_literal: true

class AddProcessorToPayments < ActiveRecord::Migration[4.2]
  def change
    add_column :payments, :processor, :string
  end
end
