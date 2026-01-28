# frozen_string_literal: true

class AddContentTypeToResourceSubscription < ActiveRecord::Migration[4.2]
  def change
    add_column :resource_subscriptions, :content_type, :string, default: "application/x-www-form-urlencoded"
  end
end
