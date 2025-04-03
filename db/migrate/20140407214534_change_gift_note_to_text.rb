# frozen_string_literal: true

class ChangeGiftNoteToText < ActiveRecord::Migration
  def up
    change_column :gifts, :gift_note, :text
  end

  def down
    change_column :links, :gift_note, :string
  end
end
