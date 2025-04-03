# frozen_string_literal: true

class ChangeCommentIdsToBigintsAndChangeItsContentLimitAndAddDeletedAt < ActiveRecord::Migration[6.1]
  def up
    change_table :comments, bulk: true do |t|
      # Added
      t.datetime :deleted_at, null: true

      # Changed
      t.change :id, :bigint, null: false, unique: true, auto_increment: true
      t.change :commentable_id, :bigint
      t.change :author_id, :bigint
    end
  end

  def down
    change_table :comments, bulk: true do |t|
      # Previously added
      t.remove :deleted_at

      # Previously changed
      t.change :id, :integer, null: false, unique: true, auto_increment: true
      t.change :commentable_id, :integer
      t.change :author_id, :integer
    end
  end
end
