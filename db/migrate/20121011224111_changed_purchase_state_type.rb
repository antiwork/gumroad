# frozen_string_literal: true

class ChangedPurchaseStateType < ActiveRecord::Migration[4.2]
  def change
    change_column :events, :purchase_state, :string
    change_column_default(:events, :purchase_state, nil)
  end
end
