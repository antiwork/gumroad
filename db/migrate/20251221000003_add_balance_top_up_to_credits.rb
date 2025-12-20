# frozen_string_literal: true

class AddBalanceTopUpToCredits < ActiveRecord::Migration[7.1]
  def change
    add_column :credits, :balance_top_up_id, :bigint
    add_index :credits, :balance_top_up_id
  end
end
