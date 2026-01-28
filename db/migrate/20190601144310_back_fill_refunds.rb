# frozen_string_literal: true

class BackFillRefunds < ActiveRecord::Migration[4.2]
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
