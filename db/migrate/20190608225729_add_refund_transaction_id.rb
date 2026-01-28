# frozen_string_literal: true

class AddRefundTransactionId < ActiveRecord::Migration[4.2]
  def change
    add_column :refunds, :processor_refund_id, :string
  end
end
