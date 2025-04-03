# frozen_string_literal: true

class DropDelayedEmails < ActiveRecord::Migration[7.0]
  def up
    drop_table :delayed_emails
  end

  def down
    create_table "delayed_emails", id: :integer, charset: "utf8mb4", collation: "utf8mb4_unicode_ci" do |t|
      t.integer "purchase_id"
      t.datetime "created_at", precision: nil
      t.datetime "updated_at", precision: nil
      t.integer "user_id"
      t.string "email_type"
    end
  end
end
