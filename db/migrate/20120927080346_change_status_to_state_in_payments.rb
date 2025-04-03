# frozen_string_literal: true

class ChangeStatusToStateInPayments < ActiveRecord::Migration
  def up
    rename_column :payments, :status, :state
  end

  def down
    rename_column :payments, :state, :status
  end
end
