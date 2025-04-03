# frozen_string_literal: true

class AddUserAgentToTwitterOrders < ActiveRecord::Migration
  def change
    add_column :twitter_orders, :user_agent, :string
  end
end
