# frozen_string_literal: true

class AddGifterEmailIndexOnGifts < ActiveRecord::Migration
  def up
    add_index :gifts, :gifter_email
  end

  def down
    remove_index :gifts, :gifter_email
  end
end
