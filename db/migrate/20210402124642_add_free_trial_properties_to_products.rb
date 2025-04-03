# frozen_string_literal: true

class AddFreeTrialPropertiesToProducts < ActiveRecord::Migration[6.1]
  def change
    change_table :links do |t|
      t.integer :free_trial_duration_unit
      t.integer :free_trial_duration_amount
    end
  end
end
