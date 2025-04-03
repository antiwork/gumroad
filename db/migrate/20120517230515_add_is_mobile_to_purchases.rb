# frozen_string_literal: true

class AddIsMobileToPurchases < ActiveRecord::Migration
  def change
    add_column :purchases, :is_mobile, :boolean
  end
end
