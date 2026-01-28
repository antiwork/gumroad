# frozen_string_literal: true

class AddBetaToUser < ActiveRecord::Migration[4.2]
  def change
    change_table :users do |t|
      t.boolean :beta
    end
  end
end
