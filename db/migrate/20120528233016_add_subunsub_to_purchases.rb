# frozen_string_literal: true

class AddSubunsubToPurchases < ActiveRecord::Migration[4.2]
  def change
    add_column :purchases, :subunsub, :string
  end
end
