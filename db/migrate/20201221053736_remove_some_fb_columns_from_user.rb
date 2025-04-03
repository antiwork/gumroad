# frozen_string_literal: true

class RemoveSomeFbColumnsFromUser < ActiveRecord::Migration[6.0]
  def up
    change_table :users do |t|
      t.remove :facebook_gender, :facebook_verified
    end
  end

  def down
    change_table :users do |t|
      t.string :facebook_gender, limit: 255
      t.string :facebook_verified, limit: 255
    end
  end
end
