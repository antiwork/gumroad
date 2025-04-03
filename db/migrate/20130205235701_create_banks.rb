# frozen_string_literal: true

class CreateBanks < ActiveRecord::Migration
  def change
    create_table :banks do |t|
      t.string  :routing_number
      t.string  :name
    end
    add_index :banks, :routing_number
  end
end
