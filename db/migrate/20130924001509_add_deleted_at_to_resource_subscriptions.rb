# frozen_string_literal: true

class AddDeletedAtToResourceSubscriptions < ActiveRecord::Migration[4.2]
  def change
    add_column :resource_subscriptions, :deleted_at, :datetime
  end
end
