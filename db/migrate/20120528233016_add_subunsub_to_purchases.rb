# frozen_string_literal: true

class AddSubunsubToPurchases < ActiveRecord::Migration
  def change
    add_column :purchases, :subunsub, :string
  end
end
