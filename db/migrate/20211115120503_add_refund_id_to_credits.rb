# frozen_string_literal: true

class AddRefundIdToCredits < ActiveRecord::Migration[6.1]
  def change
    add_column :credits, :refund_id, :integer
  end
end
