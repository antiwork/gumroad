# frozen_string_literal: true

class AddSessionIdToPurchases < ActiveRecord::Migration[4.2]
  def change
    add_column :purchases, :session_id, :string
  end
end
