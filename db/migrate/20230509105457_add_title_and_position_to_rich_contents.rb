# frozen_string_literal: true

class AddTitleAndPositionToRichContents < ActiveRecord::Migration[7.0]
  def change
    change_table :rich_contents, bulk: true do |t|
      t.string :title
      t.integer :position, default: 0, null: false
    end
  end
end
