# frozen_string_literal: true

class AddRefundIdToCredits < ActiveRecord::Migration[4.2]
  def change
    add_column :credits, :refund_id, :integer
  end
end
