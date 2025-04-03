# frozen_string_literal: true

class AddPartialRefundsToPurchase < ActiveRecord::Migration
  def change
    add_column :purchases, :stripe_partially_refunded, :boolean, default: false
  end
end
