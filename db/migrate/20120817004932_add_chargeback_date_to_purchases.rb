# frozen_string_literal: true

class AddChargebackDateToPurchases < ActiveRecord::Migration
  def change
    add_column :purchases, :chargeback_date, :datetime
  end
end
