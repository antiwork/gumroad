# frozen_string_literal: true

class AddSubscriptionIdToUrlRedirects < ActiveRecord::Migration[4.2]
  def change
    add_column :url_redirects, :subscription_id, :integer
  end
end
