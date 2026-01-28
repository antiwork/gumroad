# frozen_string_literal: true

class AddFullNameToPurchases < ActiveRecord::Migration[4.2]
  def change
    add_column :purchases, :full_name, :string
  end
end
