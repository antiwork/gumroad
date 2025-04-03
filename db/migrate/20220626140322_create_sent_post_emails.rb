# frozen_string_literal: true

class CreateSentPostEmails < ActiveRecord::Migration[6.1]
  def change
    create_table :sent_post_emails do |t|
      t.bigint :post_id, null: false
      t.string :email, null: false
      t.timestamps
      t.index [:post_id, :email], unique: true
    end
  end
end
