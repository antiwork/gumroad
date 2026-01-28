# frozen_string_literal: true

class AddCallStartTimeToCartProducts < ActiveRecord::Migration[4.2]
  def change
    add_column :cart_products, :call_start_time, :datetime
  end
end
