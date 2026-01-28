# frozen_string_literal: true

class AddIsMobileToPurchases < ActiveRecord::Migration[4.2]
  def change
    add_column :purchases, :is_mobile, :boolean
  end
end
