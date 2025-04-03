# frozen_string_literal: true

class AddIndexForRefundsProcessorRefundId < ActiveRecord::Migration
  def up
    add_index :refunds, :processor_refund_id, unique: true
  end

  def down
    remove_index :refunds, :processor_refund_id
  end
end
