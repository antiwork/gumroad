# frozen_string_literal: true

class UpdateRefundPolicies < ActiveRecord::Migration[7.1]
  def up
    add_column :refund_policies, :max_refund_period_in_days, :integer
    change_column_null :refund_policies, :title, true
    change_column_null :refund_policies, :product_id, true
  end

  def down
    remove_column :refund_policies, :max_refund_period_in_days
    change_column_null :refund_policies, :title, false
    change_column_null :refund_policies, :product_id, false
  end
end
