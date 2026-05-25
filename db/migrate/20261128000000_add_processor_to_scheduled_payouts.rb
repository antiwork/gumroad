# frozen_string_literal: true

class AddProcessorToScheduledPayouts < ActiveRecord::Migration[7.1]
  def change
    add_column :scheduled_payouts, :processor, :string
  end
end
