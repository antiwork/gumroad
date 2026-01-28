# frozen_string_literal: true

class AddUserAgentToTwitterOrders < ActiveRecord::Migration[4.2]
  def change
    add_column :twitter_orders, :user_agent, :string
  end
end
