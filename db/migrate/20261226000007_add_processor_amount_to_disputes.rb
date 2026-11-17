# frozen_string_literal: true

class AddProcessorAmountToDisputes < ActiveRecord::Migration[8.1]
  def change
    change_table :disputes, bulk: true do |t|
      t.bigint :processor_amount_cents
      t.string :processor_currency
    end
  end
end
