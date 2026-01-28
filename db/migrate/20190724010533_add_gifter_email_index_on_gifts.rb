# frozen_string_literal: true

class AddGifterEmailIndexOnGifts < ActiveRecord::Migration[4.2]
  def up
    add_index :gifts, :gifter_email
  end

  def down
    remove_index :gifts, :gifter_email
  end
end
