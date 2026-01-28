# frozen_string_literal: true

class AddFollowupCountToPurchases < ActiveRecord::Migration[4.2]
  def change
    add_column :purchases, :follow_up_count, :integer
  end
end
