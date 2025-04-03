# frozen_string_literal: true

class AddGoogleAnalyticsIdToUsers < ActiveRecord::Migration
  def change
    add_column :users, :google_analytics_id, :string
  end
end
