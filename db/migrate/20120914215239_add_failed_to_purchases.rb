# frozen_string_literal: true

class AddFailedToPurchases < ActiveRecord::Migration[4.2]
  def change
    add_column :purchases, :failed, :boolean, default: false
  end
end
