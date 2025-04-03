# frozen_string_literal: true

class AddProcessorFeeCentsToPurchases < ActiveRecord::Migration
  def change
    add_column :purchases, :processor_fee_cents, :integer
  end
end
