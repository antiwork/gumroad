# frozen_string_literal: true

class AddDeletedAtToResourceSubscriptions < ActiveRecord::Migration
  def change
    add_column :resource_subscriptions, :deleted_at, :datetime
  end
end
