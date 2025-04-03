# frozen_string_literal: true

class RemoveBackgroundColumnsFromUsers < ActiveRecord::Migration[6.1]
  def up
    change_table :users, bulk: true do |t|
      t.remove :background_color
      t.remove :background_image_url
    end
  end

  def down
    change_table :users, bulk: true do |t|
      t.string :background_color
      t.string :background_image_url
    end
  end
end
