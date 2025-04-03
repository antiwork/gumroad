# frozen_string_literal: true

class AddCallStartTimeToCartProducts < ActiveRecord::Migration[7.1]
  def change
    add_column :cart_products, :call_start_time, :datetime
  end
end
