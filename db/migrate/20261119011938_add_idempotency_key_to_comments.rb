# frozen_string_literal: true

class AddIdempotencyKeyToComments < ActiveRecord::Migration[7.2]
  def change
    add_column :comments, :idempotency_key, :string, null: true
    add_index :comments, [:commentable_type, :commentable_id, :idempotency_key],
              unique: true,
              where: "idempotency_key IS NOT NULL",
              name: "index_comments_on_commentable_and_idempotency_key"
  end
end
