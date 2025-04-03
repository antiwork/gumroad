# frozen_string_literal: true

class AddSubscriptionIdToUrlRedirects < ActiveRecord::Migration
  def change
    add_column :url_redirects, :subscription_id, :integer
  end
end
