# frozen_string_literal: true

class AddStripeMandateIdToSubscriptions < ActiveRecord::Migration[7.1]
  def change
    add_column :subscriptions, :stripe_mandate_id, :string
  end
end
