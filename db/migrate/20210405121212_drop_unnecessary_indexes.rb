# frozen_string_literal: true

class DropUnnecessaryIndexes < ActiveRecord::Migration[6.1]
  def change
    remove_index :service_charges, :processor_payment_intent_id
  end
end
