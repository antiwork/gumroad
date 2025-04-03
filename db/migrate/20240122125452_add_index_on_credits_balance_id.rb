# frozen_string_literal: true

class AddIndexOnCreditsBalanceId < ActiveRecord::Migration[7.0]
  def change
    add_index :credits, :balance_id
  end
end
