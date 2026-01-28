# frozen_string_literal: true

class AddChargebackDateToPurchases < ActiveRecord::Migration[4.2]
  def change
    add_column :purchases, :chargeback_date, :datetime
  end
end
