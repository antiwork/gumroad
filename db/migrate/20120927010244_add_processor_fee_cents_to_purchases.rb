# frozen_string_literal: true

class AddProcessorFeeCentsToPurchases < ActiveRecord::Migration[4.2]
  def change
    add_column :purchases, :processor_fee_cents, :integer
  end
end
