# frozen_string_literal: true

class AddBetaToUser < ActiveRecord::Migration
  def change
    change_table :users do |t|
      t.boolean :beta
    end
  end
end
