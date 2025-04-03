# frozen_string_literal: true

class AddProcessorFeeCentsToPayments < ActiveRecord::Migration
  def change
    add_column :payments, :processor_fee_cents, :integer
  end
end
