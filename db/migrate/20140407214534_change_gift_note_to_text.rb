# frozen_string_literal: true

class ChangeGiftNoteToText < ActiveRecord::Migration[4.2]
  def up
    change_column :gifts, :gift_note, :text
  end

  def down
    change_column :links, :gift_note, :string
  end
end
