# frozen_string_literal: true

class AddStatusToRefund < ActiveRecord::Migration
  def change
    add_column :refunds, :status, :string
  end
end
