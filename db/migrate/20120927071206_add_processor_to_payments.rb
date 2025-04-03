# frozen_string_literal: true

class AddProcessorToPayments < ActiveRecord::Migration
  def change
    add_column :payments, :processor, :string
  end
end
