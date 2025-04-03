# frozen_string_literal: true

class AddDurationToLinkAndOccurenceToSubscription < ActiveRecord::Migration
  def change
    add_column :links, :duration_in_months, :integer
    add_column :subscriptions, :charge_occurrence_count, :integer
  end
end
