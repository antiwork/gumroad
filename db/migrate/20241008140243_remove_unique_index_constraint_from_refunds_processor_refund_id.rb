# frozen_string_literal: true

class RemoveUniqueIndexConstraintFromRefundsProcessorRefundId < ActiveRecord::Migration[7.1]
  def up
    change_table :refunds, bulk: true do |t|
      t.remove_index :processor_refund_id
      t.index :processor_refund_id
    end
  end

  def down
    change_table :refunds, bulk: true do |t|
      t.remove_index :processor_refund_id
      t.index :processor_refund_id, unique: true
    end
  end
end
