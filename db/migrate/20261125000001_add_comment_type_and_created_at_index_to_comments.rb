# frozen_string_literal: true

class AddCommentTypeAndCreatedAtIndexToComments < ActiveRecord::Migration[7.1]
  def change
    add_index :comments,
              [:comment_type, :commentable_type, :created_at, :commentable_id],
              name: "index_comments_on_comment_type_and_created_at"
  end
end
