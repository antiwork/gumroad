# frozen_string_literal: true

class UpdatePurchaseRefundPolicies < ActiveRecord::Migration[7.1]
  def change
    add_column :purchase_refund_policies, :max_refund_period_in_days, :integer
  end
end
