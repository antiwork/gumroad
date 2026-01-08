# frozen_string_literal: true

class AddRefundCoverageChargeToCredits < ActiveRecord::Migration[7.0]
  def change
    add_column :credits, :refund_coverage_charge_id, :integer
    add_index :credits, :refund_coverage_charge_id
  end
end
