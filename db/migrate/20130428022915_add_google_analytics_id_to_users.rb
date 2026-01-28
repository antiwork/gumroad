# frozen_string_literal: true

class AddGoogleAnalyticsIdToUsers < ActiveRecord::Migration[4.2]
  def change
    add_column :users, :google_analytics_id, :string
  end
end
