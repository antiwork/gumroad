# frozen_string_literal: true

class CreateComments < ActiveRecord::Migration
  def change
    create_table :comments do |t|
      t.belongs_to :commentable, polymorphic: true
      t.integer :author_id
      t.string :author_name
      t.text :content
      t.string :comment_type
      t.text :json_data

      t.timestamps
    end
    add_index(:comments, [:commentable_id, :commentable_type])
  end
end
