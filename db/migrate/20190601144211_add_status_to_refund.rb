# frozen_string_literal: true

class AddStatusToRefund < ActiveRecord::Migration[4.2]
  def change
    add_column :refunds, :status, :string
  end
end
