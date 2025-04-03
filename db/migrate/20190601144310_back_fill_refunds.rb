# frozen_string_literal: true

class BackFillRefunds < ActiveRecord::Migration
  def up
    change_column_default :refunds, :status, "succeeded"
    Refund.find_each do |refund|
      refund.status = "succeeded"
      refund.save!
    end
  end

  def down
    # NOOP
  end
end
