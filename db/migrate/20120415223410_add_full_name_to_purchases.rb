# frozen_string_literal: true

class AddFullNameToPurchases < ActiveRecord::Migration
  def change
    add_column :purchases, :full_name, :string
  end
end
