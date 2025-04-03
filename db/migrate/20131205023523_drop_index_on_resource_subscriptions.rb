# frozen_string_literal: true

class DropIndexOnResourceSubscriptions < ActiveRecord::Migration
  def change
    remove_index :resource_subscriptions, name: "index_resource_subscriptions_on_user_application_resource_name"
    add_index :resource_subscriptions, :user_id
  end
end
