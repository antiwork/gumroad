# frozen_string_literal: true

class AddRefundTransactionId < ActiveRecord::Migration
  def change
    add_column :refunds, :processor_refund_id, :string
  end
end
