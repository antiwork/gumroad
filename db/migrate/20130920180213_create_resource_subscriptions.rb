# frozen_string_literal: true

class CreateResourceSubscriptions < ActiveRecord::Migration
  def change
    create_table :resource_subscriptions do |t|
      t.references :oauth_application, null: false
      t.references :user, null: false
      t.string :resource_name, null: false
      t.string :post_url

      t.timestamps
    end

    add_index :resource_subscriptions, [:user_id, :oauth_application_id, :resource_name], unique: true, name: "index_resource_subscriptions_on_user_application_resource_name"
    add_index :resource_subscriptions, :oauth_application_id
  end
end
