# frozen_string_literal: true

class AddIdempotencyKeyToComments < ActiveRecord::Migration[7.1]
  def change
    change_table :comments, bulk: true do |t|
      t.string :idempotency_key, null: true
      t.index [:commentable_type, :commentable_id, :idempotency_key],
              unique: true,
              where: "idempotency_key IS NOT NULL",
              name: "index_comments_on_commentable_and_idempotency_key"
    end
  end
end
